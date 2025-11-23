## Debug Scripts

This directory contains comprehensive debugging scripts for the cross-account event flow.

### Prerequisites

These scripts support **two authentication methods**:

#### Option 1: AWS SSO Profiles (Recommended)

```bash
# Configure AWS profiles for each account
export CORE_PROFILE=core-account
export RPS_PROFILE=rps-account
```

#### Option 2: Environment Variables

```bash
# For Core account checks, set:
export AWS_ACCESS_KEY_ID=AKIA...
export AWS_SECRET_ACCESS_KEY=...
export AWS_SESSION_TOKEN=...  # if using temporary credentials

# For RPS account checks, switch credentials:
export AWS_ACCESS_KEY_ID=AKIA...
export AWS_SECRET_ACCESS_KEY=...
export AWS_SESSION_TOKEN=...
```

### Configuration

Set your environment and source the configuration:

```bash
# Required configuration
export CDK_DEPLOYMENT_CDK_DEPLOYMENT_PREFIX=dev
export REGION=eu-west-1
export CORE_ACCOUNT_ID=111111111111
export RPS_ACCOUNT_ID=222222222222

# Optional: Set profiles for SSO (if not using environment variables)
export CORE_PROFILE=core-account
export RPS_PROFILE=rps-account

# Load configuration
source debug/00-config.sh
```

### Scripts Overview

**Scripts are numbered in the recommended usage order:**

| Script | Purpose | When to Use |
|--------|---------|-------------|
| `00-config.sh` | Configuration and setup | Automatically sourced by all other scripts |
| `01-test-upload.sh` | **START HERE** - Upload test file | Quick end-to-end test with automated troubleshooting |
| `02-trace-flow.sh` | End-to-end flow metrics | Identifies which step failed (automatically run by 01) |
| `03-check-core.sh` | Core account resources | Verify Core account S3, EventBridge, IAM (if Step 1-2 failed) |
| `04-check-rps.sh` | RPS account resources | Verify RPS account EventBus, SQS, Lambda (if Step 2-4 failed) |
| `05-check-policies.sh` | Cross-account policies | Verify all IAM and resource policies are correct |

### Quick Start

#### Recommended: Start with Test Upload

```bash
# Set your configuration
export CDK_DEPLOYMENT_CDK_DEPLOYMENT_PREFIX=dev
export CORE_ACCOUNT_ID=111111111111
export RPS_ACCOUNT_ID=222222222222
export REGION=eu-west-1
export CORE_PROFILE=core-account
export RPS_PROFILE=rps-account

# Run the test (automatically sources config)
bash debug/01-test-upload.sh
```

**This script will:**
1. Upload a test file to `input/`
2. Wait 10 seconds
3. Check if output file appears in `output/`
4. **If it fails**: Automatically run flow trace to identify the problem
5. Show you exactly which step is broken

#### Manual Flow Trace (Optional)

If you already uploaded a file and want to trace what happened:

```bash
bash debug/02-trace-flow.sh
```

This traces the event flow through all steps:
1. Core EventBridge rule triggered
2. RPS custom event bus rule triggered
3. SQS messages received
4. Lambda invocations

#### Detailed Resource Checks (If Test Fails)

```bash
# Check Core account (if Step 1 or 2 failed)
bash debug/03-check-core.sh

# Check RPS account (if Step 2, 3, or 4 failed)
bash debug/04-check-rps.sh

# Verify all cross-account policies
bash debug/05-check-policies.sh
```

### Common Debugging Workflows

#### Scenario 1: No output file created (START HERE)

```bash
bash debug/01-test-upload.sh
```

The test script will automatically:
- Upload a file
- Check for output
- Run flow tracing if it fails
- Tell you exactly which step is broken

#### Scenario 2: Already uploaded file, want to trace what happened

```bash
bash debug/02-trace-flow.sh
```

Look for zeros in the metrics:
- **Step 1 = 0**: S3 events not reaching Core EventBridge
- **Step 2 = 0**: Core EventBridge not delivering to RPS custom bus
- **Step 3 = 0**: RPS EventBridge rule not matching or not delivering to SQS
- **Step 4 = 0**: Lambda not being invoked

#### Scenario 3: Verify policy configuration

```bash
bash debug/05-check-policies.sh
```

Checks all cross-account policies:
- Core S3 bucket policy
- Core KMS key policy
- RPS custom event bus policy
- RPS SQS queue policy (critical: checks for `aws:SourceAccount` issue)
- RPS Lambda role policies

#### Scenario 4: Deep dive into specific account

```bash
# For Core account issues (Step 1 or 2 failed)
bash debug/03-check-core.sh

# For RPS account issues (Step 2, 3, or 4 failed)
bash debug/04-check-rps.sh
```

### Understanding the Event Flow

```
S3 Bucket (Core)
  ↓ EventBridge notification enabled
Core EventBridge Rule (matches: aws.s3 Object Created, input/*)
  ↓ Target: RPS custom event bus
RPS Custom Event Bus (policy allows Core account)
  ↓
RPS EventBridge Rule (matches: account=Core, source=aws.s3)
  ↓ Target: SQS queue
SQS Queue (policy allows EventBridge with SourceArn)
  ↓ Event source mapping
Lambda Function
  ↓ Processes file
S3 Bucket output/ (Core)
```

### Switching Between Accounts

#### Using Profiles

Scripts automatically use the correct profile based on `CORE_PROFILE` and `RPS_PROFILE` environment variables.

```bash
export CORE_PROFILE=core-account
export RPS_PROFILE=rps-account
source debug/00-config.sh

# Scripts will automatically use the right profile
bash debug/02-check-core.sh  # Uses CORE_PROFILE
bash debug/03-check-rps.sh   # Uses RPS_PROFILE
```

#### Using Environment Variables

Manually switch credentials between accounts:

```bash
# For Core account operations
export AWS_ACCESS_KEY_ID=<core-key>
export AWS_SECRET_ACCESS_KEY=<core-secret>
bash debug/02-check-core.sh

# Switch to RPS account
export AWS_ACCESS_KEY_ID=<rps-key>
export AWS_SECRET_ACCESS_KEY=<rps-secret>
bash debug/03-check-rps.sh
```

### Helper Functions

After sourcing `00-config.sh`, you can use these functions in your shell:

```bash
source debug/00-config.sh

# Use aws_core for Core account commands
aws_core s3 ls s3://${BUCKET_NAME}/

# Use aws_rps for RPS account commands
aws_rps sqs list-queues
```

These functions automatically handle profile or environment variable authentication.

### Troubleshooting the Scripts

#### "Configuration not loaded" error

You forgot to source the configuration:
```bash
source debug/00-config.sh
```

#### "Access Denied" errors

- **Using profiles**: Verify your AWS profiles are configured correctly
  ```bash
  aws sts get-caller-identity --profile core-account
  aws sts get-caller-identity --profile rps-account
  ```

- **Using environment variables**: Verify your credentials are set
  ```bash
  aws sts get-caller-identity
  ```

#### jq not found

Install jq for JSON parsing:
```bash
# macOS
brew install jq

# Linux
sudo apt-get install jq  # Debian/Ubuntu
sudo yum install jq      # RHEL/CentOS
```

### Output Examples

#### Successful Flow Trace

```
STEP 1: Core Account EventBridge Rule
1a. TriggeredRules: 5
1b. Invocations: 5
1c. FailedInvocations: 0
Expected: ✓

STEP 2: RPS Account Custom Event Bus Rule
2a. TriggeredRules: 5
2b. Invocations: 5
2c. FailedInvocations: 0
Expected: ✓

STEP 3: SQS Queue
3a. MessagesSent: 5
3b. MessagesReceived: 5
Expected: ✓

STEP 4: Lambda Processor
4a. Invocations: 5
4b. Errors: 0
Expected: ✓
```

#### Failed Flow (Example)

```
STEP 1: Core Account EventBridge Rule
1a. TriggeredRules: 3
1b. Invocations: 3
1c. FailedInvocations: 0
Expected: ✓

STEP 2: RPS Account Custom Event Bus Rule
2a. TriggeredRules: 0  ← PROBLEM HERE
2b. Invocations: 0
2c. FailedInvocations: 0
If TriggeredRules = 0: Events not reaching custom bus or rule pattern mismatch
```

This indicates events are reaching Core EventBridge but not the RPS custom event bus. Check:
1. Event bus policy allows Core account
2. Rule pattern matches the events
3. Core EventBridge IAM role has permissions

### Common Issues and Solutions

See [DEBUGGING.md](../DEBUGGING.md) for comprehensive troubleshooting, especially:
- **Section: Debugging Custom Event Bus Issues** - Required when using custom event bus
- **Step 7: Check SQS Queue Policy** - Critical `aws:SourceAccount` vs `aws:SourceArn` issue
