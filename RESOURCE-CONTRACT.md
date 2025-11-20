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

### S3 Bucket

**Name:** `{prefix}-core-test-bucket-{accountCoreId}-{region}`

**Example:** `alice-core-test-bucket-111111111111-eu-west-1`

**Purpose:** Stores input files (prefix: `input/`) and output files (prefix: `output/`)

**Required Permissions:**
- RPS Lambda must read from `s3://{bucketName}/input/*`
- RPS Lambda must write to `s3://{bucketName}/output/*`

**Bucket Policy Requirements:**
```json
{
  "Effect": "Allow",
  "Principal": {
    "AWS": "arn:aws:iam::{accountRpsId}:role/{prefix}-processor-lambda-role"
  },
  "Action": ["s3:GetObject", "s3:ListBucket"],
  "Resource": [
    "arn:aws:s3:::{bucketName}",
    "arn:aws:s3:::{bucketName}/input/*"
  ]
}
```

### KMS Key

**Purpose:** Encrypts S3 bucket

**Required Permissions:**
```json
{
  "Effect": "Allow",
  "Principal": {
    "AWS": "arn:aws:iam::{accountRpsId}:root"
  },
  "Action": [
    "kms:Decrypt",
    "kms:DescribeKey",
    "kms:GenerateDataKey"
  ],
  "Condition": {
    "StringEquals": {
      "kms:ViaService": "s3.{region}.amazonaws.com"
    }
  }
}
```

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
      "name": ["{bucketName}"]
    },
    "object": {
      "key": [{"prefix": "input/"}]
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

**Required IAM Role Name:** `{prefix}-processor-lambda-role` (MUST match - used in Core bucket policy)

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
// Construct Core bucket name using the contract
const stackCoreBucketName = `${prefix}-core-test-bucket-${accountCoreId}-${region}`;

// Pass to RPS stack
const stackRps = new StackRps(app, `${prefix}-StackRps`, {
  stackCoreBucketName, // Static string - no cross-account reference
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

- [ ] S3 bucket name follows: `{prefix}-core-test-bucket-{accountCoreId}-{region}`
- [ ] Bucket policy allows RPS Lambda role: `{prefix}-processor-lambda-role`
- [ ] KMS key policy allows RPS account: `{accountRpsId}`
- [ ] EventBridge rule targets RPS event bus
- [ ] EventBridge IAM role has `events:PutEvents` permission

### RPS Team Checklist

- [ ] Lambda role name is exactly: `{prefix}-processor-lambda-role` (matches Core bucket policy)
- [ ] Lambda has permissions for S3 operations
- [ ] Lambda has KMS permissions: Decrypt, DescribeKey, GenerateDataKey
- [ ] EventBridge rule filters by Core account ID
- [ ] Event bus policy allows Core account to put events

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
