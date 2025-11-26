# Cross-Account Access Infrastructure

AWS CDK TypeScript infrastructure for secure cross-account S3 access with EventBridge, SQS, and Lambda processing.

## Architecture Overview

This project implements a secure, scalable cross-account architecture with the following components:

```
Core Account                                  RPS Account
┌─────────────────────────────────┐          ┌──────────────────────────────────┐
│                                 │          │                                  │
│  Input S3 Bucket                │          │                                  │
│  (triggers events)              │          │                                  │
│            │                    │          │                                  │
│            │ ObjectCreated      │          │                                  │
│            ▼                    │          │                                  │
│  EventBridge Rule               │          │                                  │
│  (filters input bucket)         │          │                                  │
│            │                    │          │                                  │
│            │ Cross-account      │          │                                  │
│            └────────────────────┼─────────▶│  EventBridge (custom bus)        │
│                                 │          │            │                     │
│  Output S3 Bucket               │          │            ▼                     │
│  (receives results)             │          │  EventBridge Rule                │
│            ▲                    │          │  (filters Core Account events)   │
│            │                    │          │            │                     │
│  S3AccessRole (IAM)             │          │            ▼                     │
│  ├─ S3: read input bucket       │          │  SQS Queue (encrypted)           │
│  ├─ S3: write output bucket     │          │  └─ DLQ for failed messages      │
│  └─ KMS: encrypt/decrypt        │          │            │                     │
│            ▲                    │          │            ▼                     │
│            │ AssumeRole         │          │  Lambda Function                 │
│            │ (temp creds)       │          │  └─ AssumeRole Core S3AccessRole │
│            └────────────────────┼──────────┼─────────────┘                    │
│                                 │          │                                  │
└─────────────────────────────────┘          └──────────────────────────────────┘
```

## Features

- **Multi-instance deployment**: Deploy multiple isolated instances with different prefixes (e.g., dev, staging, prod)
- **AssumeRole pattern for cross-account access**:
  - Centralized S3/KMS permissions in Core account
  - Temporary credentials (1-hour validity)
  - Credential caching for performance
  - StringLike condition for restricted trust policy
- **Security best practices**:
  - KMS encryption for S3 and SQS
  - Versioned S3 buckets with lifecycle policies
  - Least-privilege IAM policies
  - SSL enforcement
  - Access logging
  - Block public access
- **CDK NAG compliant**: Passes AWS Solutions security checks
- **Comprehensive testing**: Unit tests and integration tests included

## Prerequisites

- Node.js 18+ and npm/yarn
- AWS CLI configured with credentials for both accounts
- AWS CDK CLI: `npm install -g aws-cdk`
- Access to two AWS accounts (Core Account and RPS Account)

## Installation

```bash
# Install dependencies
npm install

# Build the project
npm run build

# Run unit tests
npm test
```

## Configuration

### Environment Variables

Set the following environment variables before deployment:

```bash
export ACCOUNT_A_ID="111111111111"  # Replace with your Core Account ID
export ACCOUNT_B_ID="222222222222"  # Replace with your RPS Account ID
export STAGE="dev"                  # Deployment instance prefix
```

### Multi-Instance Deployment

The architecture supports deploying multiple instances with different prefixes. Edit `src/main.ts` to configure your deployments:

```typescript
const deployments: DeploymentConfig[] = [
  {
    prefix: 'dev',
    accountCore: { id: '111111111111', region: 'eu-central-1' },
    accountRps: { id: '222222222222', region: 'eu-central-1' },
  },
  {
    prefix: 'prod',
    accountCore: { id: '333333333333', region: 'eu-central-1' },
    accountRps: { id: '444444444444', region: 'eu-central-1' },
  },
];
```

Each instance is isolated with its own resources:
- Stack A-{prefix} and Stack B-{prefix}
- {prefix}-core-input-bucket-{account}-{region}
- {prefix}-core-output-bucket-{account}-{region}
- {prefix}-processor-queue
- {prefix}-s3-processor Lambda function

## Deployment

### Step 1: Deploy Stack A (Core Account)

First, deploy the S3 bucket and EventBridge rule in Core Account:

```bash
# Set AWS credentials for Core Account
export AWS_PROFILE=account-a  # or use AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY

# Deploy Stack A
cdk deploy dev-StackA
```

### Step 2: Deploy Stack B (RPS Account)

Then, deploy the processing pipeline in RPS Account:

```bash
# Set AWS credentials for RPS Account
export AWS_PROFILE=account-b

# Deploy Stack B
cdk deploy dev-StackB
```

### Deploying Multiple Instances

To deploy multiple instances (e.g., dev and prod):

```bash
# Deploy all stacks
cdk deploy --all

# Or deploy specific instances
cdk deploy dev-StackA dev-StackB
cdk deploy prod-StackA prod-StackB
```

## Testing the Deployment

### End-to-End Test

1. Upload a test file to the input bucket in Core Account:

```bash
export INPUT_BUCKET_NAME="dev-core-input-bucket-111111111111-eu-central-1"
export OUTPUT_BUCKET_NAME="dev-core-output-bucket-111111111111-eu-central-1"
echo "Test content" > test.txt
aws s3 cp test.txt s3://$INPUT_BUCKET_NAME/test.txt --profile account-a
```

2. Wait a few seconds for processing

3. Check the output bucket for the processed file:

```bash
aws s3 ls s3://$OUTPUT_BUCKET_NAME/ --profile account-a
aws s3 cp s3://$OUTPUT_BUCKET_NAME/test.txt - --profile account-a
```

### Integration Tests

Run the comprehensive integration test suite:

```bash
# Set environment variables
export ACCOUNT_CORE_ID="111111111111"
export ACCOUNT_RPS_ID="222222222222"
export STAGE="dev"

# Run integration tests (requires deployed stacks)
npm test -- test/integration
```

The integration tests cover:
1. **EventBridge Cross-Account Transfer**: Tests event routing from Core Account to RPS Account
2. **EventBridge-SQS Integration**: Verifies events are correctly queued in SQS
3. **Lambda S3 Operations**: Tests cross-account S3 read/write operations

## Project Structure

```
.
├── src/
│   ├── main.ts              # CDK app entry point with multi-instance config
│   ├── stack-a.ts           # Stack A: S3 bucket + EventBridge
│   └── stack-b.ts           # Stack B: EventBridge + SQS + Lambda
├── lambda/
│   └── processor.ts         # Lambda handler for S3 processing
├── test/
│   ├── main.test.ts         # Unit tests
│   └── integration/         # Integration tests
│       ├── eventbridge-cross-account.test.ts
│       ├── eventbridge-sqs.test.ts
│       └── lambda-s3-operations.test.ts
├── .projenrc.ts             # Projen configuration
└── README.md                # This file
```

## Key Resources

### Core Stack Resources

- **Input S3 Bucket**: Encrypted with KMS, versioned, with access logging, EventBridge notifications enabled
- **Output S3 Bucket**: Encrypted with KMS, versioned, with access logging
- **S3 Access Logs Bucket**: Stores access logs for both buckets
- **KMS Key**: Shared key for both S3 buckets with automatic rotation
- **S3AccessRole**: IAM role with S3/KMS permissions that RPS Lambda assumes
  - Trust policy: Allows RPS Lambda roles (using StringLike condition)
  - Permissions: S3 read (entire input bucket), write (entire output bucket), KMS encrypt/decrypt
- **EventBridge Rule**: Captures ObjectCreated events on input bucket
- **EventBridge IAM Role**: Allows EventBridge to send events to RPS Account
- **Bucket Policies**: Defense in depth - deny public access only

### RPS Stack Resources

- **SQS Queue**: Encrypted main processing queue
- **Dead Letter Queue**: For failed message handling
- **KMS Key**: For SQS encryption with automatic rotation
- **Custom Event Bus**: Receives cross-account events (shared across deployments)
- **EventBridge Rule**: Receives events from Core Account
- **Lambda Function**: Node.js 22 processor with AssumeRole cross-account access
- **Lambda IAM Role**: Execution role with ONLY sts:AssumeRole permission (cross-account)
- **Event Bus Policy**: Allows Core Account to send events

## Security Considerations

### AssumeRole Pattern

This project uses **STS AssumeRole** for cross-account S3 access instead of direct cross-account bucket policies:

- **Core Account** hosts S3AccessRole with ALL S3/KMS permissions
- **RPS Lambda** assumes this role to get temporary credentials (1-hour validity)
- **Credentials are cached** in Lambda container and reused across invocations
- **Trust policy** uses StringLike condition to restrict which roles can assume

Benefits:
- ✅ Centralized permission management
- ✅ Temporary credentials (auto-expiring)
- ✅ No complex cross-account bucket/KMS policies
- ✅ Clear CloudTrail audit trail

### IAM Permissions

**Core S3AccessRole (in Core Account):**
- S3 read access: entire input bucket
- S3 write access: entire output bucket
- KMS decrypt/encrypt for shared S3 bucket key

**RPS Lambda Role (in RPS Account):**
- Cross-account: ONLY `sts:AssumeRole` for Core S3AccessRole
- Same-account: SQS, CloudWatch Logs permissions
- NO direct S3 or KMS permissions

All permissions follow least-privilege principle.

### Encryption

- S3 buckets use KMS encryption (SSE-KMS)
- SQS queues use KMS encryption
- All KMS keys have automatic rotation enabled
- SSL/TLS enforced for all data in transit

### Access Controls

- S3 buckets have "Block Public Access" enabled
- S3AccessRole trust policy uses StringLike condition to restrict assumable roles
- Cross-account access uses temporary credentials via AssumeRole
- All S3/KMS permissions scoped to specific buckets (read input bucket, write output bucket)

## Common Operations

### View Stack Outputs

```bash
cdk deploy dev-StackA --outputs-file outputs-a.json
cdk deploy dev-StackB --outputs-file outputs-b.json
```

### View Lambda Logs

```bash
aws logs tail /aws/lambda/dev-s3-processor --follow --profile account-b
```

### Monitor SQS Queue

```bash
aws sqs get-queue-attributes \
  --queue-url https://sqs.eu-central-1.amazonaws.com/222222222222/dev-processor-queue \
  --attribute-names All \
  --profile account-b
```

### Check EventBridge Rules

```bash
# Core Account
aws events list-rules --name-prefix dev-s3 --profile account-a

# RPS Account
aws events list-rules --name-prefix dev-receive --profile account-b
```

## Cleanup

To delete all resources:

```bash
# Delete Stack B first (RPS Account)
cdk destroy dev-StackB --profile account-b

# Then delete Stack A (Core Account)
cdk destroy dev-StackA --profile account-a
```

## Troubleshooting

### Events not reaching RPS Account

1. Verify EventBridge rule in Core Account is enabled
2. Check Event Bus Policy in RPS Account allows Core Account
3. Verify IAM role in Core Account has `events:PutEvents` permission
4. Check CloudWatch Logs for EventBridge errors

### Lambda not processing files

1. Check SQS queue for messages
2. View Lambda CloudWatch Logs: `/aws/lambda/dev-s3-processor`
3. Verify Lambda role has sts:AssumeRole permission for Core S3AccessRole
4. Check S3AccessRole has S3 and KMS permissions in Core Account

### S3 Access Denied

With the AssumeRole pattern, check these in order:

1. **AssumeRole permission**: Verify Lambda role has `sts:AssumeRole` for Core S3AccessRole
2. **Trust policy**: Verify Core S3AccessRole trust policy allows Lambda role (check StringLike condition)
3. **S3 permissions**: Verify S3AccessRole has S3 read/write permissions in Core Stack
4. **KMS permissions**: Verify S3AccessRole has KMS decrypt/encrypt permissions
5. **Environment variables**: Check Lambda has `CORE_S3_ACCESS_ROLE_ARN`, `INPUT_BUCKET_NAME`, `OUTPUT_BUCKET_NAME` set correctly
6. **CloudWatch Logs**: Look for "Assuming role" or "Using cached credentials" messages
7. **Buckets**: Verify accessing correct buckets (input bucket for read, output bucket for write)

Common errors:
- `AccessDenied` on AssumeRole: Trust policy doesn't allow Lambda role
- `AccessDenied` on S3: S3AccessRole lacks S3 permissions
- `KMS.NotFoundException`: S3AccessRole lacks KMS permissions

## Development

### Adding New Instances

1. Add new deployment config in `src/main.ts`
2. Run `cdk synth` to verify
3. Deploy with `cdk deploy {prefix}-StackA {prefix}-StackB`

### Modifying Lambda Logic

1. Edit `lambda/processor.ts`
2. Run `npm run build` to test compilation
3. Deploy Stack B: `cdk deploy dev-StackB`

### Running CDK NAG

```bash
# CDK NAG runs automatically during build
npm run build

# To see detailed output
cdk synth
```

## License

Apache-2.0

## Support

For issues or questions, please refer to the CLAUDE.md file for development guidance.