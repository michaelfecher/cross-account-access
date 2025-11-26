# Cross-Account Security Policies Documentation

**Project**: Cross-Account S3 Access with EventBridge Integration
**Date**: 2025-11-26
**Accounts**: Core (111111111111) ↔ RPS (222222222222)
**Security Pattern**: AssumeRole with Temporary Credentials

---

## Table of Contents

1. [Security Architecture Overview](#security-architecture-overview)
2. [Core Account Policies](#core-account-policies)
3. [RPS Account Policies](#rps-account-policies)
4. [Cross-Account Access Chain](#cross-account-access-chain)
5. [Environment-Based Security (Dev vs Prod)](#environment-based-security)
6. [Critical Security Features](#critical-security-features)

---

## Security Architecture Overview

### Trust Model (AssumeRole Pattern)

```
┌─────────────────────────────────────────────────────────────┐
│              CROSS-ACCOUNT ACCESS VIA ASSUMEROLE             │
│                                                              │
│  Core Account (111111111111)                                │
│    ├─ Input S3 Bucket (triggers EventBridge)                │
│    ├─ Output S3 Bucket (receives processed files)           │
│    ├─ KMS Key (encrypts both buckets)                       │
│    ├─ S3AccessRole (centralizes ALL S3/KMS permissions)     │
│    │   └─ Trust Policy: ALLOW RPS Lambda roles              │
│    │       └─ Condition: StringLike on role name pattern    │
│    └─ EventBridge Role: CAN send events to RPS              │
│                                                              │
│  RPS Account (222222222222)                                  │
│    ├─ Event Bus Policy: ALLOW Core account                  │
│    ├─ Lambda Role:                                           │
│    │   └─ Permission: sts:AssumeRole on Core S3AccessRole   │
│    └─ Lambda Function:                                       │
│        └─ Assumes Core S3AccessRole → Gets temp credentials │
│        └─ Uses temp credentials for ALL S3/KMS operations   │
└─────────────────────────────────────────────────────────────┘
```

### Key Architectural Decisions

#### Why AssumeRole Instead of Direct Cross-Account Access?

**OLD Pattern** (Direct cross-account access):
- ❌ S3 bucket policy allows RPS account/roles
- ❌ KMS key policy allows RPS account/roles
- ❌ Permissions split across accounts
- ❌ Harder to audit and maintain

**NEW Pattern** (AssumeRole with centralized permissions):
- ✅ S3 bucket policy ONLY allows Core account (same-account access)
- ✅ KMS key policy ONLY allows Core account
- ✅ ALL S3/KMS permissions centralized in Core S3AccessRole
- ✅ RPS Lambda only needs `sts:AssumeRole` permission
- ✅ Clearer security boundary and audit trail
- ✅ Temporary credentials (1-hour duration, auto-expiring)

### Policy Types

| Policy Type | Location | Purpose |
|-------------|----------|---------|
| **Trust Policy** | Core S3AccessRole | Controls WHO can assume the role |
| **Permissions Policy** | Core S3AccessRole | Controls WHAT the assumed role can do (S3/KMS) |
| **Permissions Policy** | RPS Lambda Role | Controls WHAT Lambda can do (sts:AssumeRole, SQS, CloudWatch) |
| **Resource Policy** | S3 Bucket | Defense in depth (deny public access) |
| **Resource Policy** | Event Bus | Controls WHO can send events |

---

## Core Account Policies

### 1. S3AccessRole (NEW! - Centralized Permissions)

**Role Name**: `dev-s3-access-role` (or `prod-s3-access-role`)
**Purpose**: Centralizes ALL S3 and KMS permissions for RPS Lambda to assume

#### Trust Policy (Who can assume this role)

**Development Environment**:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::222222222222:root"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringLike": {
          "aws:PrincipalArn": [
            "arn:aws:iam::222222222222:role/dev-processor-lambda-role",
            "arn:aws:iam::222222222222:role/dev-*-processor-lambda-role"
          ]
        }
      }
    }
  ]
}
```

**Key Security Feature - StringLike Condition**:
- ✅ Allows: `dev-processor-lambda-role`
- ✅ Allows: `dev-john-processor-lambda-role`
- ✅ Allows: `dev-alice-processor-lambda-role`
- ✅ Allows: Any role matching `dev-*-processor-lambda-role` pattern
- ❌ Denies: `dev-admin-role` (doesn't match pattern)
- ❌ Denies: `dev-other-service-role` (doesn't match pattern)
- ❌ Denies: Any other role in RPS account

**Production Environment**:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::222222222222:role/prod-processor-lambda-role"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

**Production Security**:
- ✅ Allows: ONLY `prod-processor-lambda-role`
- ❌ Denies: All other roles (no wildcard pattern)

---

#### Permissions Policy (What the assumed role can do)

**S3 Read Permissions (Input Bucket)**:
```json
{
  "Effect": "Allow",
  "Action": [
    "s3:GetObject*",
    "s3:GetBucket*",
    "s3:List*"
  ],
  "Resource": [
    "arn:aws:s3:::dev-core-input-bucket-111111111111-eu-central-1",
    "arn:aws:s3:::dev-core-input-bucket-111111111111-eu-central-1/*"
  ]
}
```

**S3 Write Permissions (Output Bucket)**:
```json
{
  "Effect": "Allow",
  "Action": [
    "s3:DeleteObject*",
    "s3:PutObject",
    "s3:PutObjectLegalHold",
    "s3:PutObjectRetention",
    "s3:PutObjectTagging",
    "s3:PutObjectVersionTagging",
    "s3:Abort*"
  ],
  "Resource": [
    "arn:aws:s3:::dev-core-output-bucket-111111111111-eu-central-1/*"
  ]
}
```

**KMS Permissions**:
```json
{
  "Effect": "Allow",
  "Action": [
    "kms:Decrypt",
    "kms:DescribeKey",
    "kms:Encrypt",
    "kms:ReEncrypt*",
    "kms:GenerateDataKey*"
  ],
  "Resource": "arn:aws:kms:eu-central-1:111111111111:key/..."
}
```

**Key Points**:
- These permissions are in the **Core account**
- No cross-account bucket or KMS policies needed
- Same-account access is straightforward
- All permissions in one place (easier to audit)

---

### 2. S3 Bucket Policies (Defense in Depth Only)

**Input Bucket**: `arn:aws:s3:::dev-core-input-bucket-111111111111-eu-central-1`
**Output Bucket**: `arn:aws:s3:::dev-core-output-bucket-111111111111-eu-central-1`

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
      "aws:PrincipalAccount": "111111111111"
    }
  }
}
```

**Purpose**: Explicitly denies access from any principal that is:
- NOT an AWS service (like S3, CloudWatch)
- AND NOT from Core account

**Why this matters**:
- No cross-account ALLOW statements needed
- S3AccessRole is in same account, so no bucket policy needed for it
- This is pure defense in depth

---

### 3. KMS Key Policy (Core Account)

**Resource**: `arn:aws:kms:eu-central-1:111111111111:key/...`
**Alias**: `alias/dev-bucket-key`

The KMS key policy ONLY allows the Core account (specifically the S3AccessRole).

**No cross-account KMS key policy needed** because:
- S3AccessRole is in Core account (same account as KMS key)
- RPS Lambda assumes the S3AccessRole to get temporary credentials
- Those temporary credentials belong to Core account
- KMS sees requests as coming from Core account, not RPS account

---

### 4. EventBridge IAM Role (Core Account)

**Role Name**: `dev-cross-account-eventbridge-role`

#### Trust Policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "events.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

#### Permissions Policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "events:PutEvents",
      "Resource": "arn:aws:events:eu-central-1:222222222222:event-bus/dev-cross-account-bus"
    }
  ]
}
```

**Purpose**: Allows EventBridge in Core Account to send events to RPS Account's custom event bus.

---

## RPS Account Policies

### 1. Lambda Execution Role

**Role Name**: `dev-processor-lambda-role` (or `dev-john-processor-lambda-role`)

#### Trust Policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

#### Permissions Policy (Simplified!)

**A. AssumeRole Permission (Core Security Boundary)**

```json
{
  "Sid": "AssumeCoreS3AccessRole",
  "Effect": "Allow",
  "Action": "sts:AssumeRole",
  "Resource": "arn:aws:iam::111111111111:role/dev-s3-access-role"
}
```

**This is the ONLY cross-account permission Lambda needs!**

**Security Model**:
1. RPS Lambda role has explicit permission to assume Core S3AccessRole
2. Core S3AccessRole trust policy allows this specific Lambda role
3. Core S3AccessRole has ALL S3/KMS permissions
4. Lambda gets temporary credentials (1-hour duration)
5. Lambda uses temporary credentials for S3/KMS operations

---

**B. Same-Account SQS Access**

```json
{
  "Sid": "AccessSQSQueue",
  "Effect": "Allow",
  "Action": [
    "sqs:ReceiveMessage",
    "sqs:DeleteMessage",
    "sqs:GetQueueAttributes"
  ],
  "Resource": "arn:aws:sqs:eu-central-1:222222222222:dev-processor-queue"
}
```

---

**C. Same-Account KMS for SQS**

```json
{
  "Effect": "Allow",
  "Action": "kms:Decrypt",
  "Resource": "arn:aws:kms:eu-central-1:222222222222:key/..."
}
```

**Note**: This KMS key is in RPS account (different from Core's KMS key).

---

**D. CloudWatch Logs**

```json
{
  "Sid": "CloudWatchLogs",
  "Effect": "Allow",
  "Action": [
    "logs:CreateLogGroup",
    "logs:CreateLogStream",
    "logs:PutLogEvents"
  ],
  "Resource": [
    "arn:aws:logs:eu-central-1:222222222222:log-group:/aws/lambda/dev-s3-processor",
    "arn:aws:logs:eu-central-1:222222222222:log-group:/aws/lambda/dev-s3-processor:*"
  ]
}
```

---

### 2. Custom Event Bus Policy

**Resource**: `dev-cross-account-bus`

```javascript
// Created via Custom Resource (AWS SDK call)
await eventBridge.putPermission({
  EventBusName: 'dev-cross-account-bus',
  StatementId: 'AllowCoreAccount-dev',
  Principal: '111111111111',
  Action: 'events:PutEvents',
});
```

**For deployment-specific stacks**:
```javascript
StatementId: 'AllowCoreAccount-dev-john'  // Unique per deployment
```

---

## Cross-Account Access Chain

### S3 Access Flow (AssumeRole Pattern)

```
1. Lambda (RPS Account) starts processing SQS message
   ↓
2. Lambda calls sts:AssumeRole
   Request: AssumeRole on arn:aws:iam::111111111111:role/dev-s3-access-role
   ↓
3. AWS STS checks Lambda role permissions
   ✓ Does Lambda role have sts:AssumeRole permission? YES
   ✓ Resource matches Core S3AccessRole ARN? YES
   → Permission check PASSED
   ↓
4. AWS STS checks Core S3AccessRole trust policy
   ✓ Is caller from account 222222222222? YES
   ✓ Does caller ARN match StringLike pattern? YES
      - Matches: arn:aws:iam::222222222222:role/dev-*-processor-lambda-role
   → Trust check PASSED
   ↓
5. STS returns temporary credentials
   {
     AccessKeyId: ASIA...,
     SecretAccessKey: ...,
     SessionToken: ...,
     Expiration: 2025-11-26T12:48:00Z (1 hour)
   }
   ↓
6. Lambda caches credentials (5-minute expiration buffer)
   ↓
7. Lambda creates S3 client with temporary credentials
   s3Client = new S3Client({ credentials: assumedCredentials })
   ↓
8. Lambda calls S3 GetObject
   Request: GetObject on s3://input-bucket/file.txt
   Credentials: From Core S3AccessRole (Core account identity)
   ↓
9. S3 checks input bucket policy
   ✓ Is principal from Core account (111111111111)? YES
   ✓ Does S3AccessRole have s3:GetObject permission? YES
   → ALLOW (same-account access, straightforward)
   ↓
10. S3 calls KMS to decrypt object
    ↓
11. KMS checks key policy
    ✓ Is principal from Core account? YES
    ✓ Does S3AccessRole have kms:Decrypt permission? YES
    → ALLOW (same-account access)
    ↓
12. Lambda receives decrypted object
    ↓
13. Lambda processes file and calls S3 PutObject
    Request: PutObject on s3://output-bucket/file.txt
    Credentials: Same Core S3AccessRole credentials
    ↓
14. S3 checks output bucket policy
    ✓ Is principal from Core account? YES
    ✓ Does S3AccessRole have s3:PutObject permission? YES
    → ALLOW
    ↓
15. Lambda successfully writes to output bucket
```

**Key Advantages**:
- Clear security boundary at AssumeRole step
- All S3/KMS permissions in one place (Core S3AccessRole)
- Temporary credentials (auto-expiring)
- CloudTrail shows AssumeRole events for audit
- Core account maintains full control over S3/KMS access

---

### Credential Caching

**Lambda Implementation**:
```typescript
let cachedCredentials: Credentials | null = null;
let credentialsExpiration: Date | null = null;

async function getS3ClientWithAssumedRole(): Promise<S3Client> {
  const now = new Date();

  // Check if cached credentials are still valid (with 5-minute buffer)
  if (cachedCredentials && credentialsExpiration) {
    const bufferMs = 5 * 60 * 1000; // 5 minutes
    if (now.getTime() < credentialsExpiration.getTime() - bufferMs) {
      console.log('Using cached credentials');
      return new S3Client({ credentials: cachedCredentials });
    }
  }

  // Assume role to get new credentials
  console.log(`Assuming role: ${CORE_S3_ACCESS_ROLE_ARN}`);
  const assumeRoleResponse = await stsClient.send(new AssumeRoleCommand({
    RoleArn: CORE_S3_ACCESS_ROLE_ARN,
    RoleSessionName: `lambda-${PREFIX}-${Date.now()}`,
    DurationSeconds: 3600, // 1 hour
  }));

  // Cache credentials
  cachedCredentials = assumeRoleResponse.Credentials;
  credentialsExpiration = assumeRoleResponse.Credentials.Expiration!;

  return new S3Client({ credentials: cachedCredentials });
}
```

**Benefits**:
- Reduces AssumeRole API calls (~100-200ms latency)
- Reuses credentials across Lambda invocations
- Lambda container persistence maintains cache
- 5-minute buffer prevents using expired credentials

---

## Environment-Based Security

### Development Environment (STAGE=dev)

**Trust Policy Principal**:
```json
{
  "Principal": {
    "AWS": "arn:aws:iam::222222222222:root"
  },
  "Condition": {
    "StringLike": {
      "aws:PrincipalArn": [
        "arn:aws:iam::222222222222:role/dev-processor-lambda-role",
        "arn:aws:iam::222222222222:role/dev-*-processor-lambda-role"
      ]
    }
  }
}
```

**Security Layers** (Defense in Depth):
1. **Core Trust Policy**: Only roles matching `dev-*-processor-lambda-role` pattern
2. **RPS Permissions**: Lambda role must have explicit `sts:AssumeRole` permission
3. **Core S3AccessRole**: Centralized S3/KMS permissions

**Allows**:
- ✅ `dev-processor-lambda-role`
- ✅ `dev-john-processor-lambda-role`
- ✅ `dev-alice-processor-lambda-role`

**Denies**:
- ❌ `dev-admin-role`
- ❌ `dev-other-service-role`
- ❌ Any role not matching pattern

---

### Production Environment (STAGE=prod)

**Trust Policy Principal**:
```json
{
  "Principal": {
    "AWS": "arn:aws:iam::222222222222:role/prod-processor-lambda-role"
  }
}
```

**Security**:
- ✅ Specific role ARN only
- ✅ No wildcard patterns
- ✅ No StringLike condition needed
- 🔒 Maximum least privilege

---

## Critical Security Features

### 1. Defense in Depth (Three Layers)

| Layer | Control | Purpose |
|-------|---------|---------|
| **Layer 1: Core Trust Policy** | StringLike condition on role ARN pattern | Restricts which RPS roles can assume S3AccessRole |
| **Layer 2: RPS Permissions** | Explicit sts:AssumeRole permission | Lambda must have permission to assume Core role |
| **Layer 3: Core Permissions** | S3AccessRole permissions policy | Defines what assumed role can access |

**To access S3**, attacker must bypass ALL three layers:
1. ❌ Match role name pattern in Core trust policy
2. ❌ Have sts:AssumeRole permission in RPS account
3. ❌ Use assumed credentials to access S3

---

### 2. Temporary Credentials

**AssumeRole returns**:
- AccessKeyId (temporary)
- SecretAccessKey (temporary)
- SessionToken (temporary)
- Expiration (1 hour maximum)

**Security Benefits**:
- ✅ Credentials auto-expire (no permanent keys)
- ✅ Limited lifetime reduces exposure window
- ✅ Can be revoked by updating trust policy
- ✅ CloudTrail logs all AssumeRole operations

---

### 3. Least Privilege Principle

**S3AccessRole has minimal permissions**:

| Resource | Read | Write | Other |
|----------|------|-------|-------|
| `input/*` | ✅ | ❌ | ❌ |
| `output/*` | ❌ | ✅ | ❌ |
| Core KMS | ✅ (decrypt) | ✅ (encrypt) | ❌ |
| Bucket config | ❌ | ❌ | ❌ |

**Lambda Role has minimal cross-account permissions**:
- ✅ ONLY `sts:AssumeRole` on Core S3AccessRole
- ❌ NO direct S3 access
- ❌ NO direct KMS access
- ❌ NO other Core account access

---

### 4. Centralized Permission Management

**OLD Pattern**: Permissions split across accounts
```
Core Account:
  ├─ S3 bucket policy allows RPS
  └─ KMS key policy allows RPS

RPS Account:
  └─ Lambda role has S3/KMS permissions
```

**NEW Pattern**: Permissions centralized in Core
```
Core Account:
  ├─ S3AccessRole trust policy (controls WHO)
  └─ S3AccessRole permissions (controls WHAT)
      ├─ S3 read/write
      └─ KMS encrypt/decrypt

RPS Account:
  └─ Lambda role has ONLY sts:AssumeRole
```

**Benefits**:
- ✅ Single place to audit S3/KMS permissions
- ✅ Single place to modify access
- ✅ Clear security boundary (AssumeRole)
- ✅ Core account maintains full control

---

### 5. CloudTrail Audit Trail

**AssumeRole events logged**:
```json
{
  "eventName": "AssumeRole",
  "userIdentity": {
    "principalId": "...:dev-john-processor-lambda-role",
    "arn": "arn:aws:iam::222222222222:role/dev-john-processor-lambda-role"
  },
  "requestParameters": {
    "roleArn": "arn:aws:iam::111111111111:role/dev-s3-access-role",
    "roleSessionName": "lambda-dev-1732617480000"
  },
  "responseElements": {
    "assumedRoleUser": {
      "arn": "arn:aws:sts::111111111111:assumed-role/dev-s3-access-role/lambda-dev-1732617480000"
    }
  }
}
```

**S3 access events logged with assumed role identity**:
```json
{
  "eventName": "GetObject",
  "userIdentity": {
    "type": "AssumedRole",
    "principalId": "...:lambda-dev-1732617480000",
    "arn": "arn:aws:sts::111111111111:assumed-role/dev-s3-access-role/lambda-dev-1732617480000"
  }
}
```

**Audit Benefits**:
- ✅ Clear chain: RPS Lambda → AssumeRole → S3 Access
- ✅ Can see which RPS Lambda assumed which Core role
- ✅ Can see all S3 operations performed with assumed credentials
- ✅ Better security analysis and incident response

---

## Security Audit Checklist

### Core Account

- [ ] S3AccessRole exists with correct name (`{prefix}-s3-access-role`)
- [ ] S3AccessRole trust policy allows RPS Lambda roles
- [ ] Dev: Trust policy has StringLike condition for role pattern
- [ ] Prod: Trust policy specifies exact role ARN only
- [ ] S3AccessRole has S3 read permissions to `input/*`
- [ ] S3AccessRole has S3 write permissions to `output/*`
- [ ] S3AccessRole has KMS decrypt/encrypt permissions
- [ ] S3 bucket policy denies public access
- [ ] S3 bucket policy ONLY allows Core account (no cross-account statements)
- [ ] EventBridge role can send events to RPS bus

### RPS Account

- [ ] Lambda role has `sts:AssumeRole` permission with correct Core S3AccessRole ARN
- [ ] Lambda role has NO direct S3 permissions
- [ ] Lambda role has NO direct Core KMS permissions
- [ ] Lambda function has `CORE_S3_ACCESS_ROLE_ARN` environment variable
- [ ] Lambda code calls AssumeRole before accessing S3
- [ ] Lambda code caches credentials
- [ ] Custom event bus policy allows Core account

### Cross-Account

- [ ] Core Account ID correct in all ARNs (111111111111)
- [ ] RPS Account ID correct in all ARNs (222222222222)
- [ ] Region matches in all ARNs (e.g., eu-central-1)
- [ ] Role names match: Trust policy <-> Lambda sts:AssumeRole permission
- [ ] Deploy and test: AssumeRole succeeds
- [ ] Deploy and test: S3 read/write works
- [ ] CloudWatch Logs show "Assuming role" and "Assumed role successfully"

---

## Troubleshooting

### "Access Denied" when Lambda calls AssumeRole

**Check**:
1. Lambda role has `sts:AssumeRole` permission
2. Resource in permission matches Core S3AccessRole ARN exactly
3. Core S3AccessRole trust policy allows Lambda role
4. Dev: Lambda role name matches StringLike pattern
5. Check CloudWatch Logs for exact error message

### "Access Denied" when accessing S3 with assumed credentials

**Check**:
1. S3AccessRole has S3 permissions (check IAM console)
2. Accessing correct prefix (`input/*` for read, `output/*` for write)
3. Using assumed credentials (not Lambda's own credentials)
4. Check if credentials expired (should use cache with 5-min buffer)

### "Credentials expired" errors

**Check**:
1. Credential caching is implemented
2. 5-minute expiration buffer is configured
3. Lambda is re-assuming role before expiration
4. Check CloudWatch Logs for "Using cached credentials" vs "Assuming role"

### AssumeRole takes too long

**Check**:
1. Credentials are being cached across invocations
2. Lambda container is being reused (warm starts)
3. Not calling AssumeRole on every S3 operation

---

## Additional Resources

- **Architecture Diagram**: See `architecture.puml`
- **CDK Code**: `src/stack-core.ts`, `src/stack-rps.ts`
- **Lambda Function**: `lambda/processor.ts`
- **Integration Tests**: `test/integration/`
- **Claude Code Instructions**: `CLAUDE.md`

---

**Document Version**: 2.0
**Last Updated**: 2025-11-26
**Pattern**: AssumeRole with Temporary Credentials
