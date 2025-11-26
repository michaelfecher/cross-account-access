# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a **Projen-managed AWS CDK TypeScript** project implementing secure cross-account access between two AWS accounts using S3, EventBridge, SQS, and Lambda.

### Architecture Pattern

- **Core Account**: Hosts separate input and output S3 buckets. Input bucket emits EventBridge notifications. Contains S3AccessRole that RPS Lambda assumes to access S3/KMS resources.
- **RPS Account**: Receives events via EventBridge, queues them in SQS, and processes via Lambda that assumes Core S3AccessRole to read from input bucket and write to output bucket
- **Multi-instance**: Supports deploying multiple isolated environments with different prefixes (e.g., dev, staging, prod)
- **AssumeRole Pattern**: Cross-account S3 access uses STS AssumeRole for temporary credentials, centralizing all S3/KMS permissions in Core account

### Key Design Principles

1. **Prefix-based isolation**: Each deployment instance (prefix) is completely isolated from others
2. **Least-privilege IAM**: All permissions are scoped to specific resources and actions
3. **Security-first**: KMS encryption, versioning, access logging, SSL enforcement
4. **CDK NAG compliance**: Code passes AWS Solutions security checks
5. **No over-engineering**: Clean, maintainable code without unnecessary abstractions

## Common Development Commands

### Build and Test
```bash
npm run build          # Compile TypeScript, run CDK synth with NAG checks
npm test               # Run unit tests
npm test -- test/integration  # Run integration tests (requires deployed stacks)
```

### CDK Operations
```bash
cdk synth                            # Synthesize CloudFormation templates
cdk diff dev-StackCore               # Show changes for Core Stack
cdk deploy dev-StackCore --profile core-account  # Deploy Core Account stack
cdk deploy dev-StackRps --profile rps-account    # Deploy RPS Account stack
cdk destroy dev-StackRps --profile rps-account   # Destroy RPS Stack first
cdk destroy dev-StackCore --profile core-account # Then destroy Core Stack
```

### Projen Operations
```bash
npx projen             # Regenerate project files from .projenrc.ts
```

## Code Structure

### Stack Classes (src/)

**src/main.ts**
- Entry point for CDK app
- Configures single deployment via environment variables
- Creates Core Stack and RPS Stack for the configured accounts
- Stacks are deployed separately with different AWS profiles
- Applies CDK NAG checks via `Aspects.of(app).add(new AwsSolutionsChecks())`

**src/stack-core.ts** - `StackCore` class
- Creates S3 bucket with KMS encryption, versioning, access logging
- Creates access logs bucket (separate, S3-managed encryption)
- Creates KMS key for bucket (same-account access only)
- Creates S3AccessRole with trust policy allowing RPS Lambda roles to assume (using StringLike condition in dev)
- Grants S3 read (`input/*`) and write (`output/*`) permissions to S3AccessRole
- Grants KMS decrypt/encrypt permissions to S3AccessRole
- Creates EventBridge rule matching `aws.s3` events with `Object Created` detail-type and `input/` prefix filter
- Grants RPS Account EventBridge permission to send events
- Exports: `bucket`, `bucketName`, `s3AccessRole`, `s3AccessRoleArn`

**src/stack-rps.ts** - `StackRps` class
- Creates SQS queue with KMS encryption and DLQ
- Creates Lambda function with NodejsFunction construct (auto-bundles dependencies)
- Creates IAM role with specific name `{prefix}-processor-lambda-role` for Core S3AccessRole trust policy
- Grants Lambda role ONLY `sts:AssumeRole` permission for Core S3AccessRole (all S3/KMS permissions centralized in Core)
- Creates EventBridge rule to receive events from Core Account (filters by account ID)
- Routes EventBridge events to SQS
- Lambda triggered by SQS via event source mapping
- Passes Core S3AccessRole ARN to Lambda via `CORE_S3_ACCESS_ROLE_ARN` environment variable
- Exports: `processorQueue`, `processorLambda`

### Lambda Handler (lambda/)

**lambda/processor.ts**
- Handler signature: `async (event: SQSEvent): Promise<SQSBatchResponse>`
- Uses STS AssumeRole to get temporary credentials for Core S3AccessRole
- Caches credentials in Lambda container (reused across invocations until 5 minutes before expiration)
- Parses EventBridge events from SQS message body
- Reads files from `input/` prefix in Core Account's bucket using assumed role credentials
- Processes content (adds metadata header)
- Writes to `output/` prefix with metadata using assumed role credentials
- Returns `batchItemFailures` for partial batch failures (SQS reprocessing)

### Tests (test/)

**test/main.test.ts** - Unit tests
- Uses `Template.fromStack()` for snapshot/assertion testing
- Tests Core Stack creates S3 bucket with encryption and EventBridge rule
- Tests RPS Stack creates SQS queue, Lambda, and EventBridge integration

**test/integration/** - Integration tests
- Require deployed stacks and proper AWS credentials
- Use environment variables: `ACCOUNT_CORE_ID`, `ACCOUNT_RPS_ID`, `PREFIX`
- Three test scenarios:
  1. `eventbridge-cross-account.test.ts`: Tests event routing from Core Account to RPS Account
  2. `eventbridge-sqs.test.ts`: Tests EventBridge to SQS queue delivery in RPS Account
  3. `lambda-s3-operations.test.ts`: Tests Lambda reading from input bucket and writing to output bucket

## Important Implementation Details

### Cross-Account Access with AssumeRole Pattern

This project uses the **AssumeRole pattern** for cross-account S3 access, which centralizes all S3/KMS permissions in the Core account.

**Architecture:**
1. **Core Account** creates `S3AccessRole` with:
   - Trust policy allowing specific RPS Lambda roles to assume it
   - All S3 read (`input/*`) and write (`output/*`) permissions
   - All KMS encrypt/decrypt permissions

2. **RPS Account** Lambda role has:
   - ONLY `sts:AssumeRole` permission for Core S3AccessRole
   - NO direct S3 or KMS permissions

3. **Lambda runtime**:
   - Calls STS AssumeRole to get temporary credentials (1-hour validity)
   - Caches credentials in container global scope (reused across warm invocations)
   - Uses credentials with 5-minute expiration buffer

**Trust Policy Restriction:**

The Lambda IAM role must have a **specific, predictable name** because the Core S3AccessRole trust policy uses StringLike condition:

```typescript
// Dev environment - allows multiple developer deployments
Condition: {
  StringLike: {
    'aws:PrincipalArn': [
      `arn:aws:iam::${accountRpsId}:role/${prefix}-processor-lambda-role`,
      `arn:aws:iam::${accountRpsId}:role/${prefix}-*-processor-lambda-role`
    ]
  }
}
```

This is set in `src/stack-rps.ts` via:
```typescript
roleName: `${prefix}-processor-lambda-role`
// OR for deployment-specific: `${prefix}-${deploymentPrefix}-processor-lambda-role`
```

**Why AssumeRole instead of direct cross-account?**
- ✅ Centralized permission management in Core account
- ✅ Temporary credentials (auto-expiring)
- ✅ No complex cross-account bucket/KMS policies
- ✅ Clear audit trail (CloudTrail shows AssumeRole calls)
- ✅ Single point of control for security team

### CDK NAG Suppressions

CDK NAG checks are automatically applied during build. Suppressions are justified and documented:

- **Core Stack**:
  - BucketNotificationsHandler Lambda uses AWS-managed policy (stack suppression)
  - S3AccessRole wildcard S3 permissions for prefix-based access (resource suppression with regex)
  - S3AccessRole wildcard KMS permissions for S3 encryption operations (resource suppression)
- **RPS Stack**:
  - Lambda role uses AWS-managed policy for CloudWatch Logs (resource suppression)
  - Lambda runtime version check (resource suppression - Node.js 22 is latest LTS)

Suppressions use **regex patterns** for S3 ARNs to handle dynamic bucket names:
```typescript
appliesTo: [
  { regex: '/Resource::<Bucket.*\\.Arn>/input/\\*/g' },
  { regex: '/Resource::<Bucket.*\\.Arn>/output/\\*/g' },
]
```

### EventBridge Event Flow

1. Input S3 bucket emits `Object Created` event to EventBridge when file uploaded
2. EventBridge rule in Core Account matches and sends to RPS Account's EventBridge
3. EventBridge rule in RPS Account matches events from Core Account and sends to SQS
4. SQS triggers Lambda via event source mapping
5. Lambda processes SQS records containing EventBridge events

Event structure flowing through system:
```typescript
SQSRecord.body → EventBridgeEvent → detail → { bucket, object, request-id }
```

### Resource Naming Conventions

All resources follow consistent naming patterns for multi-instance support:

**Core Account:**
- S3 Bucket: `{prefix}-core-test-bucket-{accountId}-{region}`
- Access Logs Bucket: `{prefix}-core-test-access-logs-{accountId}-{region}`
- KMS Key: `alias/{prefix}-bucket-key`
- S3 Access Role: `{prefix}-s3-access-role`
- EventBridge Role: `{prefix}-cross-account-eventbridge-role`
- EventBridge Rule: `{prefix}-s3-input-events`

**RPS Account:**
- SQS Queue: `{prefix}-processor-queue` (or `{prefix}-{deploymentPrefix}-processor-queue`)
- DLQ: `{prefix}-processor-dlq` (or `{prefix}-{deploymentPrefix}-processor-dlq`)
- KMS Key: `{prefix}-queue-key` (or `{prefix}-{deploymentPrefix}-queue-key`)
- Lambda: `{prefix}-s3-processor` (or `{prefix}-{deploymentPrefix}-s3-processor`)
- Lambda Role: `{prefix}-processor-lambda-role` (or `{prefix}-{deploymentPrefix}-processor-lambda-role`)
- EventBridge Rule: `{prefix}-receive-s3-events` (or `{prefix}-{deploymentPrefix}-receive-s3-events`)
- Custom Event Bus: `{prefix}-cross-account-bus` (shared across deployments)

## Modifying the Project

### Deploying to Different Environments

Use environment variables to configure different deployments (dev, staging, prod):

```bash
# Development deployment
STAGE=dev ACCOUNT_CORE_ID=111111111111 ACCOUNT_RPS_ID=222222222222 cdk deploy dev-StackCore --profile core-dev

# Staging deployment
PREFIX=staging ACCOUNT_CORE_ID=333333333333 ACCOUNT_RPS_ID=444444444444 cdk deploy staging-StackCore --profile core-staging
```

Or update the default values in `src/main.ts` lines 15-19.

### Changing Lambda Processing Logic

1. Edit `lambda/processor.ts`
2. Modify the `processFileContent()` function
3. Run `npm run build` to verify compilation
4. Deploy: `cdk deploy {prefix}-StackRps`

### Adding New IAM Permissions

**For cross-account S3/KMS access:**

All S3 and KMS permissions are centralized in Core account's S3AccessRole. To modify:

1. Edit `src/stack-core.ts` - modify S3AccessRole permissions
2. Use `bucket.grantRead()`, `bucket.grantWrite()`, or `bucketKey.grant*()` methods
3. Add CDK NAG suppression if using wildcards (with regex patterns)
4. Document reason for permissions

**For same-account permissions (SQS, CloudWatch, etc.):**

1. Add policy statement in `src/stack-rps.ts` to `lambdaRole.addToPolicy()`
2. Add corresponding CDK NAG suppression if using wildcards
3. Document reason for permissions

**Note:** Lambda role in RPS account should ONLY have `sts:AssumeRole` permission for cross-account access. Do not add direct S3/KMS permissions.

### Updating Dependencies

**DO NOT** manually edit `package.json` - this is a Projen-managed project.

Instead:
1. Edit `.projenrc.ts`
2. Add to `deps`, `devDeps`, or update versions
3. Run `npx projen` to regenerate files
4. Run `npm install` if needed

### Handling CDK NAG Errors

If CDK NAG reports new errors after changes:

1. Understand the security concern (don't blindly suppress)
2. Fix the issue if possible (e.g., scope down permissions)
3. If suppression needed:
   - Add to appropriate stack's suppressions section
   - Provide clear `reason` explaining why it's safe
   - Use `appliesTo` to be specific about what's suppressed
   - For stack-level issues, use `NagSuppressions.addStackSuppressions()`
   - For resource issues, use `NagSuppressions.addResourceSuppressions()`

## Deployment Workflow

### Initial Deployment

1. **Configure account IDs** (choose one method):
   - Set environment variables: `ACCOUNT_CORE_ID`, `ACCOUNT_RPS_ID`, `PREFIX`, `REGION`
   - Or edit defaults in `src/main.ts` lines 15-19

2. **Bootstrap CDK** in both accounts:
   ```bash
   # Bootstrap Core Account
   cdk bootstrap aws://CORE_ACCOUNT_ID/REGION --profile core-account

   # Bootstrap RPS Account
   cdk bootstrap aws://RPS_ACCOUNT_ID/REGION --profile rps-account
   ```

3. **Deploy stacks separately** (each with appropriate credentials):
   ```bash
   # Deploy to Core Account (authenticates with core-account profile)
   cdk deploy dev-StackCore --profile core-account

   # Deploy to RPS Account (authenticates with rps-account profile)
   cdk deploy dev-StackRps --profile rps-account
   ```

### Updates

- **Core Stack changes**: Deploy Core Stack, then RPS Stack (if bucket name changed)
- **RPS Stack changes**: Deploy RPS Stack only
- **Both changed**: Deploy Core Stack first, then RPS Stack

### Teardown

**Always delete in reverse order**:
1. `cdk destroy dev-StackRps` (RPS Account)
2. `cdk destroy dev-StackCore` (Core Account)

This prevents errors from cross-account dependencies.

## Troubleshooting Common Issues

### "Suppression path did not match any resource"

This happens when using `NagSuppressions.addResourceSuppressionsByPath()` before the resource exists. Solution: Use `addStackSuppressions()` instead or move suppression to end of constructor.

### CDK NAG IAM5 wildcard errors

For S3 bucket access patterns, wildcards are necessary. Use regex patterns in stack suppressions:
```typescript
NagSuppressions.addStackSuppressions(this, [{
  id: 'AwsSolutions-IAM5',
  reason: 'Wildcard required for S3 prefix-based access',
  appliesTo: [{ regex: '/^Resource::arn:aws:s3:::.*\\/input\\/\\*$/g' }]
}]);
```

### Lambda can't access S3

With the AssumeRole pattern, check these in order:

1. **AssumeRole permission**: Lambda role has `sts:AssumeRole` permission for Core S3AccessRole ARN
2. **Trust policy**: Core S3AccessRole trust policy allows Lambda role (check StringLike condition)
3. **S3AccessRole permissions**: S3AccessRole has S3 read/write permissions in Core Stack
4. **KMS permissions**: S3AccessRole has KMS decrypt/encrypt permissions in Core Stack
5. **Environment variable**: Lambda has `CORE_S3_ACCESS_ROLE_ARN` environment variable set correctly
6. **Credential caching**: Check CloudWatch logs for "Assuming role" or "Using cached credentials" messages
7. **Buckets**: Accessing correct buckets (input bucket for read, output bucket for write)

**Common errors:**
- `AccessDenied` on AssumeRole: Trust policy doesn't allow Lambda role (check StringLike pattern)
- `AccessDenied` on S3: S3AccessRole doesn't have required S3 permissions
- `KMS.NotFoundException`: S3AccessRole doesn't have KMS permissions
- No credentials cached: AssumeRole is being called every invocation (check expiration logic)

### Events not flowing cross-account

1. Verify EventBridge rule in Core Account has correct target (RPS Account event bus ARN)
2. Check Event Bus Policy in RPS Account allows Core Account
3. Verify IAM role in Core Account for EventBridge has `events:PutEvents`
4. Check CloudWatch Logs in both accounts for errors

## File Locations Reference

- Stack definitions: `src/stack-core.ts`, `src/stack-rps.ts`
- Lambda code: `lambda/processor.ts`
- CDK app entry: `src/main.ts`
- Unit tests: `test/main.test.ts`
- Integration tests: `test/integration/*.test.ts`
- Projen config: `.projenrc.ts`
- Generated CDK config: `cdk.json` (do not edit directly)
- Generated package.json: `package.json` (do not edit directly)

## Region Support

All resources are deployed to **eu-central-1** (Frankfurt) by default. To change:

1. Update region in `DeploymentConfig` in `src/main.ts`
2. Both accounts in a deployment pair must use the same region
3. Cross-region is not currently supported (EventBridge targets same-region event bus)
