# Team Contracts - Shared Resources & Responsibilities

This document defines what each team must provide and what they consume from the other team.

## Overview

```
┌─────────────────────┐         ┌─────────────────────┐
│   CORE TEAM         │         │   RPS TEAM          │
│  (Account: Core)    │◄────────┤ (Account: RPS)      │
│                     │         │                     │
│  Provides:          │         │  Provides:          │
│  ✓ Input Bucket     │         │  ✓ Lambda Processor │
│  ✓ Output Bucket    │         │  ✓ IAM Role (named) │
│  ✓ KMS Keys         │         │  ✓ Event Bus Policy │
│  ✓ EventBridge Rule │         │  ✓ Processing Logic │
│                     │         │                     │
│  Consumes:          │         │  Consumes:          │
│  ✓ Lambda Role Name │         │  ✓ Bucket Names     │
│  ✓ Event Bus ARN    │         │  ✓ KMS Permissions  │
└─────────────────────┘         └─────────────────────┘
```

---

## What Each Team MUST Provide

### Core Team Responsibilities

The Core team **MUST** provide these resources with **exact naming**:

#### 1. S3 Buckets (CRITICAL - Must Follow Naming)

**Input Bucket Format:** `{prefix}-core-input-bucket-{coreAccountId}-{region}`

**Output Bucket Format:** `{prefix}-core-output-bucket-{coreAccountId}-{region}`

**Example:**
- Input: `alice-core-input-bucket-111111111111-eu-west-1`
- Output: `alice-core-output-bucket-111111111111-eu-west-1`

**Why:** RPS team constructs these names in code - no runtime lookup

**Code Location:** Core: `stack-core.ts`, line 62-70

**Required Configuration:**
- ✅ Input bucket: EventBridge notifications enabled
- ✅ Input bucket: KMS encryption
- ✅ Input bucket: Bucket policy allows RPS Lambda role to read
- ✅ Output bucket: KMS encryption
- ✅ Output bucket: Bucket policy allows RPS Lambda role to write

**Input Bucket Policy MUST Include:**
```json
{
  "Sid": "AllowAccountRpsLambdaRead",
  "Effect": "Allow",
  "Principal": {
    "AWS": "arn:aws:iam::{rpsAccountId}:role/{prefix}-processor-lambda-role"
  },
  "Action": ["s3:GetObject", "s3:ListBucket"],
  "Resource": [
    "arn:aws:s3:::{inputBucketName}",
    "arn:aws:s3:::{inputBucketName}/*"
  ]
}
```

**Output Bucket Policy MUST Include:**
```json
{
  "Sid": "AllowAccountRpsLambdaWrite",
  "Effect": "Allow",
  "Principal": {
    "AWS": "arn:aws:iam::{rpsAccountId}:role/{prefix}-processor-lambda-role"
  },
  "Action": ["s3:PutObject", "s3:PutObjectAcl"],
  "Resource": ["arn:aws:s3:::{outputBucketName}/*"]
}
```

#### 2. KMS Key Policies (CRITICAL - Must Allow RPS)

**Why:** RPS Lambda needs to decrypt (read from input bucket) and encrypt (write to output bucket) S3 objects

**Required Policy Statement (for both input and output bucket KMS keys):**
```json
{
  "Sid": "AllowAccountRpsLambdaDecrypt",
  "Effect": "Allow",
  "Principal": {
    "AWS": "arn:aws:iam::{rpsAccountId}:root"
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

**Note:** RPS team doesn't need the KMS Key ARNs - permission is granted at account level

#### 3. EventBridge Rule (Cross-Account Sender)

**Name:** `{prefix}-s3-input-events`

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

**Target:** `arn:aws:events:{region}:{rpsAccountId}:event-bus/default`

**IAM Role Required:**
- Must have `events:PutEvents` permission on RPS event bus
- CDK creates this automatically

---

### RPS Team Responsibilities

The RPS team **MUST** provide these resources with **exact naming**:

#### 1. Lambda IAM Role (CRITICAL - Name MUST Match)

**Name:** `{prefix}-processor-lambda-role`

**Example:** `alice-processor-lambda-role`

**Why:** Core team's S3 bucket policy explicitly trusts this exact role name

**⚠️ WARNING:** If this name doesn't match exactly, Lambda CANNOT access S3

**Code Location:** RPS: `stack-rps.ts`, line 62

**Required Permissions:**
```json
{
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": [
        "arn:aws:s3:::{inputBucketName}",
        "arn:aws:s3:::{inputBucketName}/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:PutObjectAcl"],
      "Resource": [
        "arn:aws:s3:::{outputBucketName}",
        "arn:aws:s3:::{outputBucketName}/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:GenerateDataKey"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "kms:ViaService": "s3.{region}.amazonaws.com"
        }
      }
    }
  ]
}
```

#### 2. Event Bus Policy (CRITICAL - Must Allow Core)

**Policy Statement:**
```json
{
  "Sid": "AllowCoreAccount-{prefix}",
  "Effect": "Allow",
  "Principal": {
    "AWS": "arn:aws:iam::{coreAccountId}:root"
  },
  "Action": "events:PutEvents",
  "Resource": "arn:aws:events:{region}:{rpsAccountId}:event-bus/default"
}
```

**Code Location:** RPS: `stack-rps.ts`, line 173

#### 3. EventBridge Rule (Cross-Account Receiver)

**Name:** `{prefix}-receive-s3-events`

**Event Pattern:**
```json
{
  "account": ["{coreAccountId}"],
  "source": ["aws.s3"],
  "detail-type": ["Object Created"]
}
```

**Target:** SQS queue `{prefix}-processor-queue`

---

## Information Sharing Between Teams

### What RPS Team Needs From Core Team

| Information | Format | How to Get | Example |
|------------|--------|-----------|---------|
| **Account ID** | Static | Known/configured | `111111111111` |
| **Region** | Static | Known/configured | `eu-west-1` |
| **Prefix** | Coordinated | Agree upfront | `alice` |
| **Input Bucket Name** | Constructed | Calculate: `{prefix}-core-input-bucket-{coreId}-{region}` | `alice-core-input-bucket-111111111111-eu-west-1` |
| **Output Bucket Name** | Constructed | Calculate: `{prefix}-core-output-bucket-{coreId}-{region}` | `alice-core-output-bucket-111111111111-eu-west-1` |

**How RPS constructs bucket names in code:**
```typescript
// RPS: src/main.ts, line 36-37
const inputBucketName = `${prefix}-core-input-bucket-${accountCoreId}-${region}`;
const outputBucketName = `${prefix}-core-output-bucket-${accountCoreId}-${region}`;
```

### What Core Team Needs From RPS Team

| Information | Format | How to Get | Example |
|------------|--------|-----------|---------|
| **Account ID** | Static | Known/configured | `222222222222` |
| **Region** | Static | Known/configured | `eu-west-1` |
| **Prefix** | Coordinated | Agree upfront | `alice` |
| **Lambda Role Name** | Constructed | Calculate: `{prefix}-processor-lambda-role` | `alice-processor-lambda-role` |
| **Event Bus ARN** | Constructed | Calculate: `arn:aws:events:{region}:{rpsId}:event-bus/default` | `arn:aws:events:eu-west-1:222222222222:event-bus/default` |

**How Core constructs role ARN in bucket policy:**
```typescript
// Core: stack-core.ts, line 97
'aws:PrincipalArn': `arn:aws:iam::${accountRpsId}:role/${prefix}-processor-lambda-role`
```

---

## Configuration Files

### Using Environment Variables (Recommended)

Both teams use the **same environment variables**:

```bash
# .env file (gitignored)
PREFIX=alice
ACCOUNT_CORE_ID=111111111111
ACCOUNT_RPS_ID=222222222222
REGION=eu-west-1
```

**Usage:**
```bash
# Load variables
source .env

# RPS team deploys their stack
cdk deploy ${PREFIX}-StackRps --profile rps-account

# Core team deploys their stack
cdk deploy ${PREFIX}-StackCore --profile core-account
```

### DO NOT Use CDK Context

❌ **DON'T** put prefix in `cdk.json` context:
```json
// ❌ BAD - Don't do this
{
  "context": {
    "prefix": "alice"  // This pollutes the context
  }
}
```

✅ **DO** use environment variables only:
```bash
# ✅ GOOD - Use env vars
export PREFIX=alice
cdk deploy ${PREFIX}-StackRps
```

---

## Deployment Coordination

### Initial Setup (Both Teams Deploy)

1. **Agree on prefix:** Teams coordinate on prefix (e.g., `alice`)
2. **Share account IDs:** Exchange Core and RPS account IDs
3. **Set environment variables:** Both teams set same values

```bash
# Both teams set these
export PREFIX=alice
export ACCOUNT_CORE_ID=111111111111
export ACCOUNT_RPS_ID=222222222222
export REGION=eu-west-1
```

4. **Deploy in order:**
   - Core team deploys first: `cdk deploy alice-StackCore --profile core-account`
   - RPS team deploys second: `cdk deploy alice-StackRps --profile rps-account`

### Updates After Initial Setup

**RPS team can deploy independently** as long as they don't change:
- Lambda IAM role name
- Account IDs
- Region
- Prefix

**Core team can deploy independently** as long as they don't change:
- S3 bucket name
- Account IDs
- Region
- Prefix

### Breaking Changes Requiring Coordination

If either team changes these, **both must redeploy**:

- ❌ Prefix value
- ❌ Account IDs
- ❌ Region
- ❌ Lambda role name
- ❌ Bucket name pattern
- ❌ EventBridge event pattern

---

## Validation Checklist

### Core Team Pre-Deployment Checklist

Before deploying, verify:

- [ ] Agreed on prefix with RPS team
- [ ] Set `PREFIX` environment variable
- [ ] Set `ACCOUNT_RPS_ID` to correct RPS account
- [ ] S3 bucket policy includes RPS Lambda role ARN
- [ ] KMS key policy allows RPS account
- [ ] EventBridge rule targets RPS event bus
- [ ] EventBridge IAM role has `events:PutEvents` permission

### RPS Team Pre-Deployment Checklist

Before deploying, verify:

- [ ] Agreed on prefix with Core team
- [ ] Set `PREFIX` environment variable
- [ ] Set `ACCOUNT_CORE_ID` to correct Core account
- [ ] Lambda IAM role name is exactly: `{prefix}-processor-lambda-role`
- [ ] Event bus policy allows Core account
- [ ] Lambda has S3 permissions (GetObject, PutObject)
- [ ] Lambda has KMS permissions (Decrypt, GenerateDataKey)
- [ ] Constructed bucket name matches: `{prefix}-core-test-bucket-{coreId}-{region}`

### Post-Deployment Validation

After both teams deploy:

```bash
# Core team checks
aws s3 ls s3://${PREFIX}-core-input-bucket-${ACCOUNT_CORE_ID}-${REGION}/
aws s3 ls s3://${PREFIX}-core-output-bucket-${ACCOUNT_CORE_ID}-${REGION}/

aws events describe-rule --name ${PREFIX}-s3-input-events --region ${REGION} --profile core-account

# RPS team checks
aws lambda get-function --function-name ${PREFIX}-s3-processor --region ${REGION} --profile rps-account

aws iam get-role --role-name ${PREFIX}-processor-lambda-role --profile rps-account

# Test end-to-end
aws s3 cp test-data/sample-input.txt \
  s3://${PREFIX}-core-input-bucket-${ACCOUNT_CORE_ID}-${REGION}/test-$(date +%s).txt \
  --profile core-account

# Wait 30 seconds, then check output
aws s3 ls s3://${PREFIX}-core-output-bucket-${ACCOUNT_CORE_ID}-${REGION}/ --profile core-account
```

---

## Multi-Developer Scenarios

### Scenario 1: Each Developer Has Own Stack

Alice and Bob each deploy their own isolated stacks:

```bash
# Alice's environment
export PREFIX=alice
cdk deploy alice-StackRps --profile rps-account

# Bob's environment
export PREFIX=bob
cdk deploy bob-StackRps --profile rps-account
```

**Resources created:**
- Alice: `alice-s3-processor`, `alice-processor-lambda-role`
- Bob: `bob-s3-processor`, `bob-processor-lambda-role`

**No conflicts** - completely isolated!

### Scenario 2: Shared Dev Environment

Team shares a single `dev` environment:

```bash
# Everyone uses same prefix
export PREFIX=dev
cdk deploy dev-StackRps --profile rps-account
```

**⚠️ Warning:** Only one person should deploy at a time to avoid conflicts

### Scenario 3: Feature Branch Testing

Developer tests feature branch with temporary prefix:

```bash
# Ticket-based prefix
export PREFIX=ticket-1234
cdk deploy ticket-1234-StackRps --profile rps-account

# Coordinate with Core team to also deploy with same prefix
```

---

## Troubleshooting Cross-Team Issues

### Issue: Lambda Can't Access S3

**Symptoms:** Lambda errors with `AccessDenied`

**Check:**
1. RPS Lambda role name matches exactly: `{prefix}-processor-lambda-role`
2. Core bucket policy includes this exact role ARN
3. Prefix is the same in both stacks

```bash
# Check Lambda role name
aws iam get-role --role-name ${PREFIX}-processor-lambda-role --profile rps-account | jq '.Role.RoleName'

# Check Core input bucket policy
aws s3api get-bucket-policy --bucket ${PREFIX}-core-input-bucket-${ACCOUNT_CORE_ID}-${REGION} --profile core-account | jq -r '.Policy' | jq '.Statement[] | select(.Sid | contains("AllowAccountRpsLambda"))'
```

### Issue: Events Not Crossing Accounts

**Symptoms:** Lambda not triggered, no SQS messages

**Check:**
1. Core EventBridge rule targets RPS event bus
2. RPS event bus policy allows Core account
3. Account IDs are correct in both stacks

```bash
# Check Core EventBridge target
aws events list-targets-by-rule --rule ${PREFIX}-s3-input-events --region ${REGION} --profile core-account

# Check RPS event bus policy
aws events describe-event-bus --name default --region ${REGION} --profile rps-account | jq -r '.Policy' | jq '.Statement[] | select(.Principal.AWS | contains("'${ACCOUNT_CORE_ID}'"))'
```

### Issue: Prefix Mismatch

**Symptoms:** Resources exist but don't communicate

**Root Cause:** Teams deployed with different prefixes

**Solution:**
```bash
# Verify both teams are using same prefix
echo "Core prefix should match: ${PREFIX}"
echo "RPS prefix should match: ${PREFIX}"

# Redeploy both with agreed prefix
export PREFIX=agreed-value
# Core team: cdk deploy ${PREFIX}-StackCore --profile core-account
# RPS team: cdk deploy ${PREFIX}-StackRps --profile rps-account
```

---

## Summary: Critical Contracts

### ⚠️ MUST MATCH EXACTLY

1. **Prefix** - Both teams must use identical prefix
2. **Account IDs** - Core and RPS IDs must be correct
3. **Region** - Must be the same for both stacks
4. **Lambda Role Name** - RPS must use: `{prefix}-processor-lambda-role`
5. **Bucket Names** - Must follow:
   - Input: `{prefix}-core-input-bucket-{coreId}-{region}`
   - Output: `{prefix}-core-output-bucket-{coreId}-{region}`

### ✅ Automatically Handled

1. **KMS Key ARN** - No exchange needed (granted at account level)
2. **Event Bus ARN** - Constructed from account ID
3. **IAM Policies** - Generated by CDK from templates

### 📋 Coordination Required

1. **Prefix selection** - Teams agree upfront
2. **Deployment order** - Core first, then RPS
3. **Breaking changes** - Both teams redeploy together
4. **Testing** - End-to-end validation after both deploy
