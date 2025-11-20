# Manual Testing Guide

This guide walks you through manually testing the entire cross-account event flow.

## Prerequisites

- Both stacks deployed (Core and RPS)
- AWS CLI configured with profiles:
  - `core-account` for Core Account (111111111111)
  - `rps-account` for RPS Account (222222222222)

## Test Configuration

```bash
# Set these variables for easy copy-paste
export PREFIX=dev
export CORE_ACCOUNT_ID=111111111111
export RPS_ACCOUNT_ID=222222222222
export REGION=eu-west-1
export BUCKET_NAME=${PREFIX}-core-test-bucket-${CORE_ACCOUNT_ID}-${REGION}
export QUEUE_NAME=${PREFIX}-processor-queue
export LAMBDA_NAME=${PREFIX}-s3-processor
```

---

## Step 1: Upload Test File to S3

Upload the sample file to the `input/` prefix in Core Account's S3 bucket:

```bash
# Upload test file
aws s3 cp test-data/sample-input.txt \
  s3://${BUCKET_NAME}/input/test-$(date +%s).txt \
  --profile core-account

# Verify upload
aws s3 ls s3://${BUCKET_NAME}/input/ --profile core-account
```

**Expected:** File appears in S3 bucket's `input/` prefix

---

## Step 2: Verify Core EventBridge Rule Triggered

Check CloudWatch Logs for the Core EventBridge rule:

```bash
# Get recent invocations of the Core EventBridge rule
aws events list-rule-names-by-target \
  --target-arn arn:aws:events:${REGION}:${RPS_ACCOUNT_ID}:event-bus/default \
  --profile core-account

# Check CloudWatch metrics for the rule
aws cloudwatch get-metric-statistics \
  --namespace AWS/Events \
  --metric-name Invocations \
  --dimensions Name=RuleName,Value=${PREFIX}-s3-input-events \
  --start-time $(date -u -v-5M +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 60 \
  --statistics Sum \
  --region ${REGION} \
  --profile core-account
```

**Expected:** Invocations count increases after file upload

---

## Step 3: Verify RPS EventBridge Received Event

Check the RPS EventBridge rule metrics:

```bash
# Check RPS EventBridge rule metrics
aws cloudwatch get-metric-statistics \
  --namespace AWS/Events \
  --metric-name Invocations \
  --dimensions Name=RuleName,Value=${PREFIX}-receive-s3-events \
  --start-time $(date -u -v-5M +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 60 \
  --statistics Sum \
  --region ${REGION} \
  --profile rps-account
```

**Expected:** Invocations count increases, matching Core EventBridge

---

## Step 4: Verify SQS Queue Received Message

Check the SQS queue for messages:

```bash
# Get queue URL
QUEUE_URL=$(aws sqs get-queue-url \
  --queue-name ${QUEUE_NAME} \
  --region ${REGION} \
  --profile rps-account \
  --query 'QueueUrl' \
  --output text)

echo "Queue URL: ${QUEUE_URL}"

# Check queue attributes (messages sent/received)
aws sqs get-queue-attributes \
  --queue-url ${QUEUE_URL} \
  --attribute-names All \
  --region ${REGION} \
  --profile rps-account \
  --query 'Attributes.{Sent:ApproximateNumberOfMessages,InFlight:ApproximateNumberOfMessagesNotVisible,Delayed:ApproximateNumberOfMessagesDelayed}'

# Check CloudWatch metrics for SQS
aws cloudwatch get-metric-statistics \
  --namespace AWS/SQS \
  --metric-name NumberOfMessagesSent \
  --dimensions Name=QueueName,Value=${QUEUE_NAME} \
  --start-time $(date -u -v-5M +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 60 \
  --statistics Sum \
  --region ${REGION} \
  --profile rps-account
```

**Expected:**
- `NumberOfMessagesSent` increases
- Messages appear in queue (might be 0 if Lambda already processed)

---

## Step 5: Verify Lambda Processed the Event

Check Lambda invocations and logs:

```bash
# Check Lambda metrics
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Invocations \
  --dimensions Name=FunctionName,Value=${LAMBDA_NAME} \
  --start-time $(date -u -v-5M +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 60 \
  --statistics Sum \
  --region ${REGION} \
  --profile rps-account

# Get Lambda log group
LOG_GROUP="/aws/lambda/${LAMBDA_NAME}"

# Get recent log streams
aws logs describe-log-streams \
  --log-group-name ${LOG_GROUP} \
  --order-by LastEventTime \
  --descending \
  --max-items 1 \
  --region ${REGION} \
  --profile rps-account

# Get latest log stream name
LATEST_STREAM=$(aws logs describe-log-streams \
  --log-group-name ${LOG_GROUP} \
  --order-by LastEventTime \
  --descending \
  --max-items 1 \
  --region ${REGION} \
  --profile rps-account \
  --query 'logStreams[0].logStreamName' \
  --output text)

# View logs
aws logs get-log-events \
  --log-group-name ${LOG_GROUP} \
  --log-stream-name ${LATEST_STREAM} \
  --limit 50 \
  --region ${REGION} \
  --profile rps-account \
  --query 'events[*].[timestamp,message]' \
  --output text
```

**Expected:**
- Lambda invocations increase
- Logs show: "Processing SQS event", "Successfully wrote processed file to: output/..."

---

## Step 6: Verify Output File in S3

Check that the Lambda wrote the processed file to the `output/` prefix:

```bash
# List output files
aws s3 ls s3://${BUCKET_NAME}/output/ --profile core-account

# Download and view the latest output file
LATEST_OUTPUT=$(aws s3 ls s3://${BUCKET_NAME}/output/ --profile core-account | tail -1 | awk '{print $4}')

echo "Latest output file: ${LATEST_OUTPUT}"

# Download and display content
aws s3 cp s3://${BUCKET_NAME}/output/${LATEST_OUTPUT} - --profile core-account

# Check file metadata
aws s3api head-object \
  --bucket ${BUCKET_NAME} \
  --key output/${LATEST_OUTPUT} \
  --profile core-account \
  --query '{ContentType:ContentType,Metadata:Metadata}'
```

**Expected:**
- File exists in `output/` prefix
- Content includes processing header: "# Processed by dev at [timestamp]"
- Metadata includes: `sourceKey`, `processedBy`, `processedAt`

---

## Step 7: Compare Input vs Output

Compare the original file with the processed output:

```bash
# Get the input file name (from output file name)
INPUT_KEY="input/${LATEST_OUTPUT}"

echo "Comparing files:"
echo "Input:  s3://${BUCKET_NAME}/${INPUT_KEY}"
echo "Output: s3://${BUCKET_NAME}/output/${LATEST_OUTPUT}"

# Download both files
aws s3 cp s3://${BUCKET_NAME}/${INPUT_KEY} /tmp/input.txt --profile core-account
aws s3 cp s3://${BUCKET_NAME}/output/${LATEST_OUTPUT} /tmp/output.txt --profile core-account

# Show differences
echo "--- INPUT FILE ---"
cat /tmp/input.txt
echo ""
echo "--- OUTPUT FILE (with processing header) ---"
cat /tmp/output.txt
```

**Expected:**
- Output file contains processing metadata header
- Output file contains original content below the header

---

## Troubleshooting Commands

### Check for Errors

```bash
# Check DLQ for failed messages
DLQ_URL=$(aws sqs get-queue-url \
  --queue-name ${PREFIX}-processor-dlq \
  --region ${REGION} \
  --profile rps-account \
  --query 'QueueUrl' \
  --output text)

aws sqs get-queue-attributes \
  --queue-url ${DLQ_URL} \
  --attribute-names ApproximateNumberOfMessages \
  --region ${REGION} \
  --profile rps-account

# Check Lambda errors
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

# Search Lambda logs for errors
aws logs filter-log-events \
  --log-group-name /aws/lambda/${LAMBDA_NAME} \
  --start-time $(date -u -v-10M +%s)000 \
  --filter-pattern "ERROR" \
  --region ${REGION} \
  --profile rps-account
```

### Check EventBridge Rule Configuration

```bash
# Core Account EventBridge rule
aws events describe-rule \
  --name ${PREFIX}-s3-input-events \
  --region ${REGION} \
  --profile core-account

aws events list-targets-by-rule \
  --rule ${PREFIX}-s3-input-events \
  --region ${REGION} \
  --profile core-account

# RPS Account EventBridge rule
aws events describe-rule \
  --name ${PREFIX}-receive-s3-events \
  --region ${REGION} \
  --profile rps-account

aws events list-targets-by-rule \
  --rule ${PREFIX}-receive-s3-events \
  --region ${REGION} \
  --profile rps-account
```

### Check IAM Permissions

```bash
# Check Lambda role
aws iam get-role \
  --role-name ${PREFIX}-processor-lambda-role \
  --region ${REGION} \
  --profile rps-account

# List Lambda role policies
aws iam list-attached-role-policies \
  --role-name ${PREFIX}-processor-lambda-role \
  --region ${REGION} \
  --profile rps-account

aws iam list-role-policies \
  --role-name ${PREFIX}-processor-lambda-role \
  --region ${REGION} \
  --profile rps-account

# Check S3 bucket policy (Core Account)
aws s3api get-bucket-policy \
  --bucket ${BUCKET_NAME} \
  --profile core-account \
  --query 'Policy' \
  --output text | jq '.'
```

---

## Success Criteria

✅ **All steps completed successfully if:**

1. ✅ File uploaded to `input/` prefix
2. ✅ Core EventBridge rule invoked
3. ✅ RPS EventBridge rule invoked
4. ✅ SQS queue received message
5. ✅ Lambda processed message successfully
6. ✅ Output file created in `output/` prefix with processing header
7. ✅ No messages in DLQ
8. ✅ No Lambda errors

---

## Clean Up Test Files

After testing, clean up the test files:

```bash
# Remove test files from input/
aws s3 rm s3://${BUCKET_NAME}/input/ --recursive --profile core-account

# Remove test files from output/
aws s3 rm s3://${BUCKET_NAME}/output/ --recursive --profile core-account

# Purge SQS queue (if needed)
aws sqs purge-queue \
  --queue-url ${QUEUE_URL} \
  --region ${REGION} \
  --profile rps-account
```

---

## Performance Testing

To test at scale, upload multiple files:

```bash
# Upload 10 test files
for i in {1..10}; do
  echo "Test file $i - $(date)" > /tmp/test-$i.txt
  aws s3 cp /tmp/test-$i.txt \
    s3://${BUCKET_NAME}/input/load-test-$i.txt \
    --profile core-account
  echo "Uploaded file $i"
  sleep 1
done

# Wait 30 seconds for processing
sleep 30

# Check results
echo "Input files:"
aws s3 ls s3://${BUCKET_NAME}/input/ --profile core-account | wc -l

echo "Output files:"
aws s3 ls s3://${BUCKET_NAME}/output/ --profile core-account | wc -l

echo "DLQ messages (should be 0):"
aws sqs get-queue-attributes \
  --queue-url ${DLQ_URL} \
  --attribute-names ApproximateNumberOfMessages \
  --region ${REGION} \
  --profile rps-account
```
