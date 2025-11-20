#!/usr/bin/env bash
#
# Check RPS Account resources and configuration
#
# Prerequisites: Source 00-config.sh first
#
# Usage:
#   source debug/00-config.sh
#   bash debug/03-check-rps.sh

set -e

if [ -z "$PREFIX" ]; then
  echo "Error: Configuration not loaded. Run: source debug/00-config.sh"
  exit 1
fi

echo "=========================================="
echo "RPS Account Resources Check"
echo "=========================================="
echo ""

# Custom Event Bus
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "1. Custom Event Bus Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Bus: $CUSTOM_EVENT_BUS"
echo ""

echo "1a. Event bus details:"
aws_rps events describe-event-bus \
  --name "$CUSTOM_EVENT_BUS" \
  --region "$REGION" | jq '{
  Name: .Name,
  Arn: .Arn
}'

echo ""
echo "1b. Event bus policy:"
aws_rps events describe-event-bus \
  --name "$CUSTOM_EVENT_BUS" \
  --region "$REGION" \
  --query 'Policy' \
  --output text | jq '.Statement[] | {
  Sid: .Sid,
  Effect: .Effect,
  Principal: .Principal,
  Action: .Action,
  Resource: .Resource
}'

echo ""
echo "Expected: Allow Core account ($CORE_ACCOUNT_ID) to PutEvents"
echo ""

# EventBridge Rule on Custom Bus
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "2. EventBridge Rule on Custom Bus"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Rule: $RPS_EVENTBRIDGE_RULE"
echo ""

echo "2a. Rule details:"
aws_rps events describe-rule \
  --name "$RPS_EVENTBRIDGE_RULE" \
  --event-bus-name "$CUSTOM_EVENT_BUS" \
  --region "$REGION" | jq '{
  Name: .Name,
  State: .State,
  EventPattern: .EventPattern | fromjson
}'

echo ""
echo "2b. Rule targets:"
aws_rps events list-targets-by-rule \
  --rule "$RPS_EVENTBRIDGE_RULE" \
  --event-bus-name "$CUSTOM_EVENT_BUS" \
  --region "$REGION" | jq '.Targets[] | {
  Id: .Id,
  Arn: .Arn
}'

echo ""
echo "Expected target: arn:aws:sqs:${REGION}:${RPS_ACCOUNT_ID}:${QUEUE_NAME}"
echo ""

# SQS Queue
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "3. SQS Queue Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Queue: $QUEUE_NAME"
echo ""

QUEUE_URL=$(aws_rps sqs get-queue-url \
  --queue-name "$QUEUE_NAME" \
  --region "$REGION" \
  --query 'QueueUrl' \
  --output text)

echo "Queue URL: $QUEUE_URL"
echo ""

echo "3a. Queue attributes:"
aws_rps sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names All \
  --region "$REGION" | jq '.Attributes | {
  QueueArn: .QueueArn,
  VisibilityTimeout: .VisibilityTimeout,
  RedrivePolicy: .RedrivePolicy | fromjson,
  KmsMasterKeyId: .KmsMasterKeyId
}'

echo ""
echo "3b. Queue policy (IMPORTANT - check for SourceAccount issue):"
aws_rps sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names Policy \
  --region "$REGION" \
  --query 'Attributes.Policy' \
  --output text | jq '.Statement[] | {
  Sid: .Sid,
  Effect: .Effect,
  Principal: .Principal,
  Action: .Action,
  Condition: .Condition
}'

echo ""
echo "CRITICAL: Check for aws:SourceAccount condition"
echo "If you see: {\"StringEquals\": {\"aws:SourceAccount\": \"$RPS_ACCOUNT_ID\"}}"
echo "This blocks cross-account events! Should use aws:SourceArn instead."
echo ""
echo "Expected: AllowEventBridgeRuleSendMessage with aws:SourceArn condition"
echo ""

# Lambda Function
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "4. Lambda Function Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Function: $LAMBDA_NAME"
echo ""

echo "4a. Function details:"
aws_rps lambda get-function \
  --function-name "$LAMBDA_NAME" \
  --region "$REGION" | jq '.Configuration | {
  FunctionName: .FunctionName,
  Runtime: .Runtime,
  Role: .Role,
  Timeout: .Timeout,
  MemorySize: .MemorySize
}'

echo ""
echo "4b. Event source mappings:"
aws_rps lambda list-event-source-mappings \
  --function-name "$LAMBDA_NAME" \
  --region "$REGION" | jq '.EventSourceMappings[] | {
  UUID: .UUID,
  State: .State,
  EventSourceArn: .EventSourceArn,
  BatchSize: .BatchSize,
  LastProcessingResult: .LastProcessingResult
}'

echo ""
echo "Expected: State = Enabled, EventSourceArn = SQS queue ARN"
echo ""

# Lambda IAM Role
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "5. Lambda IAM Role Policies"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
LAMBDA_ROLE_ARN=$(aws_rps lambda get-function \
  --function-name "$LAMBDA_NAME" \
  --region "$REGION" \
  --query 'Configuration.Role' \
  --output text)

ROLE_NAME=$(echo "$LAMBDA_ROLE_ARN" | cut -d'/' -f2)
echo "Role: $ROLE_NAME"
echo ""

echo "5a. Inline policies:"
for policy in $(aws_rps iam list-role-policies \
  --role-name "$ROLE_NAME" \
  --query 'PolicyNames' \
  --output text); do
  echo ""
  echo "Policy: $policy"
  aws_rps iam get-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "$policy" \
    --query 'PolicyDocument.Statement[]' | jq '.[] | {
    Sid: .Sid,
    Effect: .Effect,
    Action: .Action,
    Resource: .Resource,
    Condition: .Condition
  }'
done

echo ""
echo "Expected policies:"
echo "  - CloudWatchLogs: logs:CreateLogGroup, logs:CreateLogStream, logs:PutLogEvents"
echo "  - ReadFromStackCoreBucket: s3:GetObject, s3:ListBucket on $BUCKET_NAME/input/*"
echo "  - WriteToStackCoreBucket: s3:PutObject on $BUCKET_NAME/output/*"
echo "  - DecryptStackCoreBucket: kms:Decrypt, kms:DescribeKey, kms:GenerateDataKey"
echo "  - AccessSQSQueue: sqs:ReceiveMessage, sqs:DeleteMessage, etc."
echo ""

# DLQ Check
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "6. Dead Letter Queue Status"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
DLQ_NAME="${PREFIX}-processor-dlq"
echo "DLQ: $DLQ_NAME"
echo ""

DLQ_URL=$(aws_rps sqs get-queue-url \
  --queue-name "$DLQ_NAME" \
  --region "$REGION" \
  --query 'QueueUrl' \
  --output text 2>/dev/null || echo "Not found")

if [ "$DLQ_URL" != "Not found" ]; then
  aws_rps sqs get-queue-attributes \
    --queue-url "$DLQ_URL" \
    --attribute-names ApproximateNumberOfMessages \
    --region "$REGION" | jq '.Attributes'

  echo ""
  echo "If messages > 0: Lambda failed to process messages 3+ times"
  echo "Check Lambda logs for errors"
else
  echo "DLQ not found"
fi
echo ""

echo "=========================================="
echo "RPS Account Check Complete"
echo "=========================================="
