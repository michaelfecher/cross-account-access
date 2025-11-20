# Debugging Guide - No Output File

When no output file is created, check each step in the flow to identify where it's breaking.

## Configuration

```bash
export PREFIX=dev
export CORE_ACCOUNT_ID=111111111111
export RPS_ACCOUNT_ID=222222222222
export REGION=eu-west-1
export BUCKET_NAME=${PREFIX}-core-test-bucket-${CORE_ACCOUNT_ID}-${REGION}
export QUEUE_NAME=${PREFIX}-processor-queue
export LAMBDA_NAME=${PREFIX}-s3-processor
```

---

## Quick Start: Automated Debug Scripts

For faster debugging, use the automated scripts in the `debug/` directory:

```bash
# 1. Configure and load environment
export PREFIX=dev
export CORE_ACCOUNT_ID=111111111111
export RPS_ACCOUNT_ID=222222222222
export REGION=eu-west-1
export CORE_PROFILE=core-account  # Optional: for SSO profiles
export RPS_PROFILE=rps-account    # Optional: for SSO profiles

source debug/00-config.sh

# 2. Run end-to-end flow trace (identifies which step is failing)
bash debug/01-trace-flow.sh

# 3. Test with actual file upload
bash debug/04-test-upload.sh

# 4. Verify all policies are correct
bash debug/05-check-policies.sh
```

See [debug/README.md](debug/README.md) for full documentation.

---

## End-to-End Flow Tracing with Metrics

**Use this to quickly identify which step in the event flow is failing.**

The event flows through these steps:
1. **Core EventBridge Rule** - Matches S3 events and sends to RPS custom bus
2. **RPS Custom Event Bus Rule** - Matches events from Core account and sends to SQS
3. **SQS Queue** - Receives events and triggers Lambda
4. **Lambda Function** - Processes file from input/ and writes to output/

### Quick Metrics Check

Run this to see metrics for the last 10 minutes at each step:

```bash
# Set time range (last 10 minutes)
if [[ "$OSTYPE" == "darwin"* ]]; then
  START_TIME=$(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ)
  END_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
else
  START_TIME=$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
  END_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
fi

# Step 1: Core EventBridge Rule Triggered
echo "Step 1: Core EventBridge Rule"
aws cloudwatch get-metric-data \
  --metric-data-queries '[{
    "Id":"triggered",
    "MetricStat":{
      "Metric":{"Namespace":"AWS/Events","MetricName":"TriggeredRules",
        "Dimensions":[{"Name":"RuleName","Value":"'${PREFIX}'-s3-input-events"}]},
      "Period":60,"Stat":"Sum"}}]' \
  --start-time "$START_TIME" --end-time "$END_TIME" \
  --region ${REGION} --profile core-account \
  --query 'MetricDataResults[0].Values' | jq 'add // 0'

# Step 2: RPS Custom Bus Rule Triggered
echo "Step 2: RPS Custom Bus Rule"
aws cloudwatch get-metric-data \
  --metric-data-queries '[{
    "Id":"triggered",
    "MetricStat":{
      "Metric":{"Namespace":"AWS/Events","MetricName":"TriggeredRules",
        "Dimensions":[{"Name":"RuleName","Value":"'${PREFIX}'-receive-s3-events"}]},
      "Period":60,"Stat":"Sum"}}]' \
  --start-time "$START_TIME" --end-time "$END_TIME" \
  --region ${REGION} --profile rps-account \
  --query 'MetricDataResults[0].Values' | jq 'add // 0'

# Step 3: SQS Messages Sent
echo "Step 3: SQS Messages"
aws cloudwatch get-metric-statistics \
  --namespace AWS/SQS --metric-name NumberOfMessagesSent \
  --dimensions Name=QueueName,Value=${QUEUE_NAME} \
  --start-time "$START_TIME" --end-time "$END_TIME" \
  --period 600 --statistics Sum --region ${REGION} \
  --profile rps-account --query 'Datapoints[0].Sum // `0`'

# Step 4: Lambda Invocations
echo "Step 4: Lambda Invocations"
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda --metric-name Invocations \
  --dimensions Name=FunctionName,Value=${LAMBDA_NAME} \
  --start-time "$START_TIME" --end-time "$END_TIME" \
  --period 600 --statistics Sum --region ${REGION} \
  --profile rps-account --query 'Datapoints[0].Sum // `0`'
```

### Interpreting Results

| Step | Metric > 0? | If Zero, Check... |
|------|-------------|-------------------|
| 1. Core EventBridge | ✓ | S3 EventBridge enabled? Rule pattern correct? |
| 2. RPS Custom Bus | ✓ | Event bus policy? Core EventBridge role permissions? |
| 3. SQS Messages | ✓ | SQS queue policy (aws:SourceArn vs aws:SourceAccount)? |
| 4. Lambda | ✓ | Event source mapping enabled? Lambda permissions? |

**Pro Tip**: Use `bash debug/01-trace-flow.sh` to run this automatically with detailed output.

---

## Step 1: Verify S3 Event Was Created

Check if S3 actually sent an event to EventBridge:

```bash
# Check S3 bucket has EventBridge notifications enabled
aws s3api get-bucket-notification-configuration \
  --bucket ${BUCKET_NAME} \
  --profile core-account

# Should show: "EventBridgeConfiguration": {}
```

**If empty or missing EventBridge config:**
- S3 bucket doesn't have EventBridge enabled
- Check stack-core.ts line 72: `eventBridgeEnabled: true`
- Redeploy Core Stack

---

## Step 2: Check Core EventBridge Rule

Verify the EventBridge rule exists and has the right pattern:

```bash
# Describe the rule
aws events describe-rule \
  --name ${PREFIX}-s3-input-events \
  --region ${REGION} \
  --profile core-account

# Check the event pattern
aws events describe-rule \
  --name ${PREFIX}-s3-input-events \
  --region ${REGION} \
  --profile core-account \
  --query 'EventPattern' \
  --output text | jq '.'

# Check targets
aws events list-targets-by-rule \
  --rule ${PREFIX}-s3-input-events \
  --region ${REGION} \
  --profile core-account
```

**Expected EventPattern:**
```json
{
  "source": ["aws.s3"],
  "detail-type": ["Object Created"],
  "detail": {
    "bucket": {
      "name": ["dev-core-test-bucket-111111111111-eu-west-1"]
    },
    "object": {
      "key": [{"prefix": "input/"}]
    }
  }
}
```

**Expected Target:**
- RPS Account custom event bus ARN: `arn:aws:events:eu-west-1:222222222222:event-bus/${PREFIX}-cross-account-bus`

---

## Step 3: Test Core EventBridge Rule Manually

Send a test event to verify the rule matches:

```bash
# Put a test event directly to Core EventBridge
aws events put-events \
  --entries '[
    {
      "Source": "aws.s3",
      "DetailType": "Object Created",
      "Detail": "{\"version\":\"0\",\"bucket\":{\"name\":\"'${BUCKET_NAME}'\"},\"object\":{\"key\":\"input/test-debug.txt\",\"size\":1024},\"request-id\":\"test-'$(date +%s)'\"}",
      "Resources": ["arn:aws:s3:::'${BUCKET_NAME}'/input/test-debug.txt"]
    }
  ]' \
  --region ${REGION} \
  --profile core-account

# Check if event was sent
echo "Check RPS EventBridge/SQS for this test event in 5 seconds..."
```

---

## Step 4: Check RPS Custom Event Bus Policy

Verify RPS custom event bus allows Core account to send events:

```bash
# Check custom event bus policy
aws events describe-event-bus \
  --name ${PREFIX}-cross-account-bus \
  --region ${REGION} \
  --profile rps-account \
  --query 'Policy' \
  --output text | jq '.'
```

**Expected Policy:**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowCoreAccount-dev",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::111111111111:root"
      },
      "Action": "events:PutEvents",
      "Resource": "arn:aws:events:eu-west-1:222222222222:event-bus/dev-cross-account-bus"
    }
  ]
}
```

---

## Step 5: Check RPS EventBridge Rule on Custom Bus

Verify RPS EventBridge rule on the custom event bus is configured correctly:

```bash
# Describe the rule
aws events describe-rule \
  --name ${PREFIX}-receive-s3-events \
  --event-bus-name ${PREFIX}-cross-account-bus \
  --region ${REGION} \
  --profile rps-account

# Check event pattern
aws events describe-rule \
  --name ${PREFIX}-receive-s3-events \
  --event-bus-name ${PREFIX}-cross-account-bus \
  --region ${REGION} \
  --profile rps-account \
  --query 'EventPattern' \
  --output text | jq '.'

# Check targets
aws events list-targets-by-rule \
  --rule ${PREFIX}-receive-s3-events \
  --event-bus-name ${PREFIX}-cross-account-bus \
  --region ${REGION} \
  --profile rps-account
```

**Expected EventPattern:**
```json
{
  "account": ["111111111111"],
  "source": ["aws.s3"],
  "detail-type": ["Object Created"]
}
```

**Expected Target:**
- SQS Queue ARN: `arn:aws:sqs:eu-west-1:222222222222:dev-processor-queue`

---

## Step 6: Check SQS Queue

Check if messages are reaching the SQS queue:

```bash
# Get queue URL
QUEUE_URL=$(aws sqs get-queue-url \
  --queue-name ${QUEUE_NAME} \
  --region ${REGION} \
  --profile rps-account \
  --query 'QueueUrl' \
  --output text)

echo "Queue URL: ${QUEUE_URL}"

# Check queue attributes
aws sqs get-queue-attributes \
  --queue-url ${QUEUE_URL} \
  --attribute-names All \
  --region ${REGION} \
  --profile rps-account | jq '.Attributes | {
  MessagesAvailable: .ApproximateNumberOfMessages,
  MessagesInFlight: .ApproximateNumberOfMessagesNotVisible,
  MessagesDelayed: .ApproximateNumberOfMessagesDelayed,
  MessagesSent: .NumberOfMessagesSent,
  MessagesReceived: .NumberOfMessagesReceived
}'

# Peek at messages without consuming them
aws sqs receive-message \
  --queue-url ${QUEUE_URL} \
  --max-number-of-messages 1 \
  --visibility-timeout 10 \
  --region ${REGION} \
  --profile rps-account
```

**If no messages:**
- EventBridge rule in RPS is not matching or not routing to SQS
- Check SQS queue policy allows EventBridge to send messages

---

## Step 7: Check SQS Queue Policy

Verify EventBridge can send messages to SQS:

```bash
# Get queue policy
aws sqs get-queue-attributes \
  --queue-url ${QUEUE_URL} \
  --attribute-names Policy \
  --region ${REGION} \
  --profile rps-account \
  --query 'Attributes.Policy' \
  --output text | jq '.'
```

**Expected:** Policy allowing `events.amazonaws.com` to send messages

---

## Step 8: Check Lambda Event Source Mapping

Verify Lambda is connected to SQS:

```bash
# List event source mappings
aws lambda list-event-source-mappings \
  --function-name ${LAMBDA_NAME} \
  --region ${REGION} \
  --profile rps-account

# Check if enabled
aws lambda list-event-source-mappings \
  --function-name ${LAMBDA_NAME} \
  --region ${REGION} \
  --profile rps-account \
  --query 'EventSourceMappings[0].{State:State,Enabled:State,BatchSize:BatchSize,LastProcessingResult:LastProcessingResult}'
```

**Expected:**
- State: "Enabled"
- EventSourceArn: SQS queue ARN

---

## Step 9: Check Lambda Invocations

Check if Lambda was invoked at all:

```bash
# Check Lambda metrics (last 10 minutes)
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Invocations \
  --dimensions Name=FunctionName,Value=${LAMBDA_NAME} \
  --start-time $(date -u -v-10M +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 60 \
  --statistics Sum \
  --region ${REGION} \
  --profile rps-account

# Check for errors
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Errors \
  --dimensions Name=FunctionName,Value=${LAMBDA_NAME} \
  --start-time $(date -u -v-10M +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 60 \
  --statistics Sum \
  --region ${REGION} \
  --profile rps-account
```

---

## Step 10: Check Lambda Logs

View Lambda execution logs:

```bash
# Tail logs in real-time
aws logs tail /aws/lambda/${LAMBDA_NAME} \
  --follow \
  --region ${REGION} \
  --profile rps-account

# Or get recent logs
aws logs tail /aws/lambda/${LAMBDA_NAME} \
  --since 10m \
  --region ${REGION} \
  --profile rps-account

# Search for errors
aws logs filter-log-events \
  --log-group-name /aws/lambda/${LAMBDA_NAME} \
  --start-time $(date -u -v-10M +%s)000 \
  --filter-pattern "ERROR" \
  --region ${REGION} \
  --profile rps-account
```

**Look for:**
- "Processing SQS event"
- "Successfully wrote processed file to: output/..."
- Any error messages

---

## Step 11: Check DLQ for Failed Messages

Check if messages failed and went to DLQ:

```bash
# Get DLQ URL
DLQ_URL=$(aws sqs get-queue-url \
  --queue-name ${PREFIX}-processor-dlq \
  --region ${REGION} \
  --profile rps-account \
  --query 'QueueUrl' \
  --output text)

# Check DLQ attributes
aws sqs get-queue-attributes \
  --queue-url ${DLQ_URL} \
  --attribute-names ApproximateNumberOfMessages \
  --region ${REGION} \
  --profile rps-account

# Peek at DLQ messages
aws sqs receive-message \
  --queue-url ${DLQ_URL} \
  --max-number-of-messages 1 \
  --region ${REGION} \
  --profile rps-account
```

**If messages in DLQ:**
- Lambda failed to process messages 3+ times
- Check Lambda logs for errors

---

## Step 12: Test Lambda Manually

Invoke Lambda directly with a test event:

```bash
# Create test event file
cat > /tmp/test-event.json <<EOF
{
  "Records": [
    {
      "messageId": "test-manual",
      "body": "{\"version\":\"0\",\"id\":\"test-$(date +%s)\",\"detail-type\":\"Object Created\",\"source\":\"aws.s3\",\"account\":\"${CORE_ACCOUNT_ID}\",\"time\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"region\":\"${REGION}\",\"resources\":[\"arn:aws:s3:::${BUCKET_NAME}/input/test.txt\"],\"detail\":{\"version\":\"0\",\"bucket\":{\"name\":\"${BUCKET_NAME}\"},\"object\":{\"key\":\"input/manual-test.txt\",\"size\":100},\"request-id\":\"manual-test\"}}",
      "attributes": {},
      "messageAttributes": {},
      "md5OfBody": "",
      "eventSource": "aws:sqs",
      "eventSourceARN": "arn:aws:sqs:${REGION}:${RPS_ACCOUNT_ID}:${QUEUE_NAME}",
      "awsRegion": "${REGION}"
    }
  ]
}
EOF

# First, create the test input file
echo "Manual test file content" | aws s3 cp - \
  s3://${BUCKET_NAME}/input/manual-test.txt \
  --profile core-account

# Invoke Lambda
aws lambda invoke \
  --function-name ${LAMBDA_NAME} \
  --payload file:///tmp/test-event.json \
  --region ${REGION} \
  --profile rps-account \
  /tmp/lambda-response.json

# Check response
cat /tmp/lambda-response.json

# Check if output file was created
aws s3 ls s3://${BUCKET_NAME}/output/manual-test.txt --profile core-account
aws s3 cp s3://${BUCKET_NAME}/output/manual-test.txt - --profile core-account
```

---

## Step 13: Check Lambda IAM Permissions

Verify Lambda has permissions to access Core S3:

```bash
# Get Lambda role
LAMBDA_ROLE=$(aws lambda get-function \
  --function-name ${LAMBDA_NAME} \
  --region ${REGION} \
  --profile rps-account \
  --query 'Configuration.Role' \
  --output text)

echo "Lambda Role ARN: ${LAMBDA_ROLE}"

# Get role name
ROLE_NAME=$(echo ${LAMBDA_ROLE} | cut -d'/' -f2)

# List inline policies
aws iam list-role-policies \
  --role-name ${ROLE_NAME} \
  --profile rps-account

# Get inline policy documents
for policy in $(aws iam list-role-policies --role-name ${ROLE_NAME} --profile rps-account --query 'PolicyNames' --output text); do
  echo "=== Policy: $policy ==="
  aws iam get-role-policy \
    --role-name ${ROLE_NAME} \
    --policy-name $policy \
    --profile rps-account \
    --query 'PolicyDocument' | jq '.'
done
```

**Expected permissions:**
- S3: GetObject, ListBucket on `input/*`
- S3: PutObject on `output/*`
- KMS: Decrypt, DescribeKey
- SQS: ReceiveMessage, DeleteMessage, etc.

---

## Step 14: Check Core S3 Bucket Policy

Verify Core bucket allows RPS Lambda to access it:

```bash
# Get bucket policy
aws s3api get-bucket-policy \
  --bucket ${BUCKET_NAME} \
  --profile core-account \
  --query 'Policy' \
  --output text | jq '.'
```

**Expected statements:**
1. Allow RPS Lambda role to GetObject from `input/*`
2. Allow RPS Lambda role to PutObject to `output/*`

**Lambda Role ARN should be:** `arn:aws:iam::222222222222:role/dev-processor-lambda-role`

---

## Debugging Custom Event Bus Issues

When using a custom event bus (required when SCP blocks `events:PutPermission` on default bus), follow these additional steps:

### Step A: Verify Events Reach Custom Bus

Create a catch-all rule to see if events are arriving:

```bash
# Create catch-all rule
aws events put-rule \
  --name debug-catch-all \
  --event-bus-name ${PREFIX}-cross-account-bus \
  --event-pattern '{"source": [{"prefix": ""}]}' \
  --state ENABLED \
  --profile rps-account

# Create log group
aws logs create-log-group \
  --log-group-name /aws/events/${PREFIX}-debug \
  --profile rps-account

# Add resource policy for EventBridge to write logs
aws logs put-resource-policy \
  --policy-name EventBridgeToLogs \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "events.amazonaws.com"},
      "Action": ["logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "arn:aws:logs:'${REGION}':'${RPS_ACCOUNT_ID}':log-group:/aws/events/*"
    }]
  }' \
  --profile rps-account

# Add CloudWatch Logs as target
aws events put-targets \
  --rule debug-catch-all \
  --event-bus-name ${PREFIX}-cross-account-bus \
  --targets '[{"Id":"debug-logs","Arn":"arn:aws:logs:'${REGION}':'${RPS_ACCOUNT_ID}':log-group:/aws/events/'${PREFIX}'-debug"}]' \
  --profile rps-account

# Upload test file and check logs
aws s3 cp test-data/sample-input.txt \
  s3://${BUCKET_NAME}/input/test-debug.txt \
  --profile core-account

sleep 30

aws logs tail /aws/events/${PREFIX}-debug --profile rps-account
```

### Step B: Check Custom Bus Rule Metrics

```bash
# Check if rule on custom bus is triggered
aws cloudwatch get-metric-data \
  --metric-data-queries '[{"Id":"m1","MetricStat":{"Metric":{"Namespace":"AWS/Events","MetricName":"TriggeredRules","Dimensions":[{"Name":"RuleName","Value":"'${PREFIX}'-receive-s3-events"}]},"Period":60,"Stat":"Sum"}}]' \
  --start-time $(date -u -v-5M +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --profile rps-account
```

### Step C: Check SQS Queue Policy for SourceAccount Issue

**Common Issue**: CDK adds a restrictive `aws:SourceAccount` condition to the SQS policy:

```bash
aws sqs get-queue-attributes \
  --queue-url https://sqs.${REGION}.amazonaws.com/${RPS_ACCOUNT_ID}/${PREFIX}-processor-queue \
  --attribute-names Policy \
  --profile rps-account | jq -r '.Attributes.Policy' | jq .
```

**Problem**: If you see this condition:
```json
"Condition": {
  "StringEquals": {
    "aws:SourceAccount": "<RPS_ACCOUNT_ID>"
  }
}
```

This blocks EventBridge from sending messages when events originate from another account.

**Solution**: The code includes an explicit policy statement using `aws:SourceArn` that allows the specific EventBridge rule to send messages. Redeploy the RPS stack if this is missing.

### Step D: Verify Custom Bus Event Pattern Match

Check the actual event structure vs rule pattern:

```bash
# Get event from debug logs
aws logs filter-log-events \
  --log-group-name /aws/events/${PREFIX}-debug \
  --limit 1 \
  --profile rps-account \
  --query 'events[0].message' --output text | jq '{account, source, "detail-type": ."detail-type"}'

# Compare with rule pattern
aws events describe-rule \
  --name ${PREFIX}-receive-s3-events \
  --event-bus-name ${PREFIX}-cross-account-bus \
  --profile rps-account \
  --query 'EventPattern' --output text | jq .
```

### Step E: Cleanup Debug Resources

After debugging, remove the catch-all rule:

```bash
aws events remove-targets \
  --rule debug-catch-all \
  --event-bus-name ${PREFIX}-cross-account-bus \
  --ids debug-logs \
  --profile rps-account

aws events delete-rule \
  --name debug-catch-all \
  --event-bus-name ${PREFIX}-cross-account-bus \
  --profile rps-account

aws logs delete-log-group \
  --log-group-name /aws/events/${PREFIX}-debug \
  --profile rps-account
```

---

## Common Issues & Fixes

### Issue 1: EventBridge not enabled on S3
```bash
# Check in stack-core.ts line 72
eventBridgeEnabled: true,
```

### Issue 2: Event pattern mismatch
- Check bucket name matches exactly
- Check prefix filter is `input/` (with trailing slash)

### Issue 3: Cross-account event bus policy missing
```bash
# Redeploy RPS Stack to recreate policy
cdk deploy dev-StackRps --profile rps-account
```

### Issue 4: Lambda not triggered by SQS
```bash
# Check event source mapping state
aws lambda list-event-source-mappings \
  --function-name ${LAMBDA_NAME} \
  --profile rps-account
```

### Issue 5: Lambda permission errors
- Check Lambda logs for "AccessDenied" errors
- Verify bucket policy in Core Account
- Verify Lambda role policies in RPS Account

---

## Quick Diagnostic Script

Run all checks at once:

```bash
echo "=== 1. S3 EventBridge Config ==="
aws s3api get-bucket-notification-configuration --bucket ${BUCKET_NAME} --profile core-account | jq '.'

echo -e "\n=== 2. Core EventBridge Rule ==="
aws events describe-rule --name ${PREFIX}-s3-input-events --region ${REGION} --profile core-account

echo -e "\n=== 3. RPS Custom Event Bus Policy ==="
aws events describe-event-bus --name ${PREFIX}-cross-account-bus --region ${REGION} --profile rps-account --query 'Policy' --output text | jq '.'

echo -e "\n=== 4. RPS EventBridge Rule ==="
aws events describe-rule --name ${PREFIX}-receive-s3-events --event-bus-name ${PREFIX}-cross-account-bus --region ${REGION} --profile rps-account

echo -e "\n=== 5. SQS Queue Stats ==="
QUEUE_URL=$(aws sqs get-queue-url --queue-name ${QUEUE_NAME} --region ${REGION} --profile rps-account --query 'QueueUrl' --output text)
aws sqs get-queue-attributes --queue-url ${QUEUE_URL} --attribute-names All --region ${REGION} --profile rps-account | jq '.Attributes | {Messages: .ApproximateNumberOfMessages, Sent: .NumberOfMessagesSent}'

echo -e "\n=== 6. Lambda Invocations (last 10m) ==="
aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name Invocations --dimensions Name=FunctionName,Value=${LAMBDA_NAME} --start-time $(date -u -v-10M +%Y-%m-%dT%H:%M:%S) --end-time $(date -u +%Y-%m-%dT%H:%M:%S) --period 600 --statistics Sum --region ${REGION} --profile rps-account --query 'Datapoints[0].Sum'

echo -e "\n=== 7. Lambda Errors (last 10m) ==="
aws cloudwatch get-metric-statistics --namespace AWS/Lambda --metric-name Errors --dimensions Name=FunctionName,Value=${LAMBDA_NAME} --start-time $(date -u -v-10M +%Y-%m-%dT%H:%M:%S) --end-time $(date -u +%Y-%m-%dT%H:%M:%S) --period 600 --statistics Sum --region ${REGION} --profile rps-account --query 'Datapoints[0].Sum'

echo -e "\n=== 8. Recent Lambda Logs ==="
aws logs tail /aws/lambda/${LAMBDA_NAME} --since 5m --region ${REGION} --profile rps-account | tail -20
```
