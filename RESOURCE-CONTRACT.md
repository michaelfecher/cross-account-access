# Resource Naming Contract

This document defines the static naming conventions that both Core and RPS teams must follow for cross-account integration.

## Purpose

- Enables independent deployments without runtime dependencies
- Allows multiple developers to deploy isolated stacks
- Provides predictable resource names for cross-team references

## Naming Convention

All resources follow the pattern: `{prefix}-{resource-type}-{identifiers}`

### Variables

- **`prefix`**: Developer/environment identifier (e.g., `dev`, `alice`, `bob`, `staging`, `prod`)
- **`accountCoreId`**: Core AWS Account ID (e.g., `111111111111`)
- **`accountRpsId`**: RPS AWS Account ID (e.g., `222222222222`)
- **`region`**: AWS Region (e.g., `eu-west-1`)

---

## Core Team Resources (Stack Core)

### Input S3 Bucket

**Name:** `{prefix}-core-input-bucket-{accountCoreId}-{region}`

**Example:** `alice-core-input-bucket-111111111111-eu-west-1`

**Purpose:** Receives files to be processed, triggers EventBridge notifications

### Output S3 Bucket

**Name:** `{prefix}-core-output-bucket-{accountCoreId}-{region}`

**Example:** `alice-core-output-bucket-111111111111-eu-west-1`

**Purpose:** Stores processed files written by RPS Lambda

**Access Pattern:** Cross-account access via AssumeRole (NOT direct bucket policy)
- RPS Lambda assumes Core S3AccessRole to get temporary credentials
- S3AccessRole has read access to entire input bucket
- S3AccessRole has write access to entire output bucket

**Bucket Policies:** Defense in depth only (denies public access)

Both buckets have the same policy:
```json
{
  "Sid": "DenyPublicAccess",
  "Effect": "Deny",
  "Principal": "*",
  "Action": "s3:*",
  "Resource": [
    "arn:aws:s3:::{bucketName}",
    "arn:aws:s3:::{bucketName}/*"
  ],
  "Condition": {
    "Bool": {
      "aws:PrincipalIsAWSService": "false"
    },
    "StringNotEquals": {
      "aws:PrincipalAccount": ["{accountCoreId}"]
    }
  }
}
```

### KMS Key

**Alias:** `alias/{prefix}-bucket-key`

**Purpose:** Encrypts S3 bucket

**Access Pattern:** Same-account access only (via S3AccessRole)
- S3AccessRole in Core account has KMS permissions
- When RPS Lambda assumes S3AccessRole, it uses Core account credentials
- KMS sees requests from Core account (same-account access)

**No Cross-Account KMS Policy Needed!**

The KMS key policy only needs to allow the Core account. Since S3AccessRole is in the same account, no special cross-account policy is required.

### S3AccessRole (IAM Role)

**Name:** `{prefix}-s3-access-role`

**Example:** `alice-s3-access-role`

**Purpose:** Centralized IAM role that RPS Lambda assumes to access S3/KMS resources

**Trust Policy:**
```json
{
  "Effect": "Allow",
  "Principal": {
    "AWS": "arn:aws:iam::{accountRpsId}:root"
  },
  "Action": "sts:AssumeRole",
  "Condition": {
    "StringLike": {
      "aws:PrincipalArn": [
        "arn:aws:iam::{accountRpsId}:role/{prefix}-processor-lambda-role",
        "arn:aws:iam::{accountRpsId}:role/{prefix}-*-processor-lambda-role"
      ]
    }
  }
}
```

**Note:** The StringLike condition restricts which roles can assume this role. Only roles matching the pattern `{prefix}-processor-lambda-role` or `{prefix}-*-processor-lambda-role` are allowed.

**Permissions Policy:**
- S3 read: `s3:GetObject*`, `s3:GetBucket*`, `s3:List*` on entire input bucket
- S3 write: `s3:PutObject`, `s3:DeleteObject*`, `s3:Abort*` on entire output bucket
- KMS: `kms:Decrypt`, `kms:Encrypt`, `kms:GenerateDataKey*` on shared bucket KMS key

**Session Duration:** 1 hour (credentials cached by Lambda)

### EventBridge Rule

**Name:** `{prefix}-s3-input-events`

**Purpose:** Captures S3 ObjectCreated events for `input/` prefix

**Target:** RPS Account EventBridge (`arn:aws:events:{region}:{accountRpsId}:event-bus/default`)

**Event Pattern:**
```json
{
  "source": ["aws.s3"],
  "detail-type": ["Object Created"],
  "detail": {
    "bucket": {
      "name": ["{inputBucketName}"]
    }
  }
}
```

---

## RPS Team Resources (Stack RPS)

### Lambda Function

**Name:** `{prefix}-s3-processor`

**Example:** `alice-s3-processor`

**Purpose:** Processes files from Core S3

**Required IAM Role Name:** `{prefix}-processor-lambda-role` (MUST match - used in Core S3AccessRole trust policy)

**Cross-Account Access Pattern:**
1. Lambda calls STS AssumeRole for `arn:aws:iam::{accountCoreId}:role/{prefix}-s3-access-role`
2. Receives temporary credentials (valid for 1 hour)
3. Caches credentials in container (reused across invocations)
4. Uses credentials for all S3/KMS operations

**Required IAM Permissions (RPS Lambda Role):**
- Cross-account: `sts:AssumeRole` for Core S3AccessRole ARN
- Same-account: SQS, CloudWatch Logs permissions
- **NO direct S3 or KMS permissions needed** (all in Core S3AccessRole)

**Environment Variables:**
- `CORE_S3_ACCESS_ROLE_ARN`: ARN of Core S3AccessRole to assume
- `INPUT_BUCKET_NAME`: Core input S3 bucket name
- `OUTPUT_BUCKET_NAME`: Core output S3 bucket name
- `PREFIX`: Deployment prefix

### SQS Queue

**Name:** `{prefix}-processor-queue`

**Example:** `alice-processor-queue`

**Purpose:** Buffers EventBridge events before Lambda processing

### EventBridge Rule

**Name:** `{prefix}-receive-s3-events`

**Purpose:** Receives cross-account events from Core Account

**Event Pattern:**
```json
{
  "account": ["{accountCoreId}"],
  "source": ["aws.s3"],
  "detail-type": ["Object Created"]
}
```

---

## Multi-Developer Setup

### Per-Developer Prefixes

Each developer uses their own prefix to isolate resources:

```bash
# Alice's deployment
PREFIX=alice ACCOUNT_CORE_ID=111111111111 ACCOUNT_RPS_ID=222222222222 \
  cdk deploy alice-StackCore --profile core-account

PREFIX=alice ACCOUNT_CORE_ID=111111111111 ACCOUNT_RPS_ID=222222222222 \
  cdk deploy alice-StackRps --profile rps-account

# Bob's deployment
PREFIX=bob ACCOUNT_CORE_ID=111111111111 ACCOUNT_RPS_ID=222222222222 \
  cdk deploy bob-StackCore --profile core-account

PREFIX=bob ACCOUNT_CORE_ID=111111111111 ACCOUNT_RPS_ID=222222222222 \
  cdk deploy bob-StackRps --profile rps-account
```

### Environment Prefixes

For shared environments:

- `dev` - Development environment (default)
- `staging` - Staging environment
- `prod` - Production environment

---

## RPS Team: How to Reference Core Resources

### In Code (src/main.ts)

```typescript
// Construct Core bucket names using the contract
const stackCoreInputBucketName = `${prefix}-core-input-bucket-${accountCoreId}-${region}`;
const stackCoreOutputBucketName = `${prefix}-core-output-bucket-${accountCoreId}-${region}`;

// Pass to RPS stack
const stackRps = new StackRps(app, `${prefix}-StackRps`, {
  stackCoreInputBucketName, // Static string - no cross-account reference
  stackCoreOutputBucketName, // Static string - no cross-account reference
  // ...
});
```

### Key Benefits

✅ **No runtime dependencies** - RPS team doesn't need to query Core stack
✅ **Independent deployments** - Teams deploy separately
✅ **Predictable naming** - Both teams follow same convention
✅ **Multi-developer support** - Each dev has isolated resources

---

## Validation Checklist

Before deploying, verify:

### Core Team Checklist

- [ ] Input bucket name follows: `{prefix}-core-input-bucket-{accountCoreId}-{region}`
- [ ] Output bucket name follows: `{prefix}-core-output-bucket-{accountCoreId}-{region}`
- [ ] S3AccessRole name is exactly: `{prefix}-s3-access-role`
- [ ] S3AccessRole trust policy uses StringLike condition to restrict RPS Lambda roles
- [ ] S3AccessRole has S3 read permissions for entire input bucket
- [ ] S3AccessRole has S3 write permissions for entire output bucket
- [ ] S3AccessRole has KMS decrypt/encrypt permissions
- [ ] EventBridge rule targets RPS custom event bus
- [ ] EventBridge rule filters by input bucket name
- [ ] EventBridge IAM role has `events:PutEvents` permission

### RPS Team Checklist

- [ ] Lambda role name is exactly: `{prefix}-processor-lambda-role` (matches Core S3AccessRole trust policy)
- [ ] Lambda role has `sts:AssumeRole` permission for Core S3AccessRole ARN
- [ ] Lambda has NO direct S3 or KMS permissions (uses AssumeRole instead)
- [ ] Lambda has `CORE_S3_ACCESS_ROLE_ARN`, `INPUT_BUCKET_NAME`, `OUTPUT_BUCKET_NAME` environment variables set
- [ ] Lambda code implements AssumeRole credential caching
- [ ] EventBridge rule filters by Core account ID and input bucket name
- [ ] Custom event bus exists and allows Core account to put events

---

## Example Deployments

### Development (Shared)

```bash
export PREFIX=dev
export ACCOUNT_CORE_ID=111111111111
export ACCOUNT_RPS_ID=222222222222
export REGION=eu-west-1

# Core team deploys
cdk deploy dev-StackCore --profile core-account

# RPS team deploys (independently, different credentials)
cdk deploy dev-StackRps --profile rps-account
```

### Per-Developer (Isolated)

```bash
# Alice's environment
export PREFIX=alice
export ACCOUNT_CORE_ID=111111111111
export ACCOUNT_RPS_ID=222222222222
export REGION=eu-west-1

cdk deploy alice-StackCore --profile core-account
cdk deploy alice-StackRps --profile rps-account

# Bob's environment (completely isolated)
export PREFIX=bob
# ... same pattern
```

### Production

```bash
export PREFIX=prod
export ACCOUNT_CORE_ID=111111111111  # Prod Core account
export ACCOUNT_RPS_ID=222222222222   # Prod RPS account
export REGION=eu-west-1

cdk deploy prod-StackCore --profile core-prod
cdk deploy prod-StackRps --profile rps-prod
```

---

## Breaking Changes

If the naming convention needs to change, both teams must coordinate:

1. **Document the change** in this file
2. **Update both stacks** in the same release cycle
3. **Test in development** with a temporary prefix first
4. **Deploy Core first**, then RPS

---

## Contact

- **Core Team:** [Core team contact/channel]
- **RPS Team:** [RPS team contact/channel]
- **Contract Changes:** Submit PR to this document and notify both teams
