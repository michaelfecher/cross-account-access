# Cross-Account Access Infrastructure

AWS CDK TypeScript infrastructure for secure cross-account S3 access with EventBridge, SQS, and Lambda processing.

## Architecture Overview

This project implements a secure, scalable cross-account architecture with the following components:

```
Core Account                                  RPS Account
┌─────────────────────────────────┐          ┌──────────────────────────────────┐
│                                 │          │                                  │
│  S3 Bucket                      │          │                                  │
│  ├─ input/  (triggers events)   │          │                                  │
│  └─ output/ (receives results)  │          │                                  │
│            │                    │          │                                  │
│            │ ObjectCreated      │          │                                  │
│            ▼                    │          │                                  │
│  EventBridge Rule               │          │                                  │
│  (filters input/ prefix)        │          │                                  │
│            │                    │          │                                  │
│            │ Cross-account      │          │                                  │
│            └────────────────────┼─────────▶│  EventBridge (default bus)       │
│                                 │          │            │                     │
│                                 │          │            ▼                     │
│                                 │          │  EventBridge Rule                │
│                                 │          │  (filters Core Account events)   │
│                                 │          │            │                     │
│                                 │          │            ▼                     │
│                                 │          │  SQS Queue (encrypted)           │
│                                 │          │  └─ DLQ for failed messages      │
│                                 │          │            │                     │
│                                 │          │            ▼                     │
│                                 │          │  Lambda Function                 │
│                                 │          │  ├─ Read: s3://bucket/input/*    │
│                                 │◀─────────┼──┴─ Write: s3://bucket/output/*  │
│                                 │          │                                  │
└─────────────────────────────────┘          └──────────────────────────────────┘
```

## Features

- **Multi-instance deployment**: Deploy multiple isolated instances with different prefixes (e.g., dev, staging, prod)
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
- {prefix}-core-test-bucket-{account}-{region}
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

1. Upload a test file to the input prefix in Core Account's bucket:

```bash
export BUCKET_NAME="dev-core-test-bucket-111111111111-eu-central-1"
echo "Test content" > test.txt
aws s3 cp test.txt s3://$BUCKET_NAME/input/test.txt --profile account-a
```

2. Wait a few seconds for processing

3. Check the output prefix for the processed file:

```bash
aws s3 ls s3://$BUCKET_NAME/output/ --profile account-a
aws s3 cp s3://$BUCKET_NAME/output/test.txt - --profile account-a
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

### Stack A Resources

- **S3 Bucket**: Encrypted with KMS, versioned, with access logging
- **S3 Access Logs Bucket**: Stores access logs for the main bucket
- **KMS Key**: For S3 bucket encryption with automatic rotation
- **EventBridge Rule**: Captures ObjectCreated events on input/ prefix
- **IAM Role**: Allows EventBridge to send events to RPS Account
- **Bucket Policies**: Grant RPS Account Lambda read (input/*) and write (output/*) access

### Stack B Resources

- **SQS Queue**: Encrypted main processing queue
- **Dead Letter Queue**: For failed message handling
- **KMS Key**: For SQS encryption with automatic rotation
- **EventBridge Rule**: Receives events from Core Account
- **Lambda Function**: Node.js 20 processor with cross-account S3 access
- **IAM Role**: Lambda execution role with least-privilege permissions
- **Event Bus Policy**: Allows Core Account to send events

## Security Considerations

### IAM Permissions

- Lambda role in RPS Account has **read-only** access to `s3://{bucket}/input/*`
- Lambda role in RPS Account has **write-only** access to `s3://{bucket}/output/*`
- All permissions are scoped to specific resources using least-privilege principle
- KMS keys grant cross-account decrypt permissions via service-specific conditions

### Encryption

- S3 buckets use KMS encryption (SSE-KMS)
- SQS queues use KMS encryption
- All KMS keys have automatic rotation enabled
- SSL/TLS enforced for all data in transit

### Access Controls

- S3 buckets have "Block Public Access" enabled
- Bucket policies require specific IAM role ARNs
- Cross-account access is explicitly granted and scoped by prefix

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
3. Verify Lambda IAM role has S3 permissions
4. Check KMS key policy allows Lambda role to decrypt

### S3 Access Denied

1. Verify bucket policy in Stack A allows RPS Account role
2. Check KMS key policy allows cross-account access
3. Ensure Lambda role ARN matches the one in bucket policy
4. Verify you're accessing the correct prefixes (input/ vs output/)

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