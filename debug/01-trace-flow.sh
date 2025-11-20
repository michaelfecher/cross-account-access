#!/usr/bin/env bash
#
# End-to-end flow tracing for cross-account event delivery
# Checks metrics at each step to identify where events are getting stuck
#
# Prerequisites: Source 00-config.sh first
#
# Usage:
#   source debug/00-config.sh
#   bash debug/01-trace-flow.sh

set -e

if [ -z "$PREFIX" ]; then
  echo "Error: Configuration not loaded. Run: source debug/00-config.sh"
  exit 1
fi

echo "=========================================="
echo "Cross-Account Event Flow Tracing"
echo "=========================================="
echo ""
echo "Checking metrics for the last 10 minutes..."
echo ""

# Calculate time range (last 10 minutes)
if [[ "$OSTYPE" == "darwin"* ]]; then
  # macOS
  START_TIME=$(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ)
  END_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
else
  # Linux
  START_TIME=$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
  END_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
fi

# Step 1: Core EventBridge Rule Metrics
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STEP 1: Core Account EventBridge Rule"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Rule: $CORE_EVENTBRIDGE_RULE"
echo ""

echo "1a. TriggeredRules (how many times rule matched):"
aws_core cloudwatch get-metric-data \
  --metric-data-queries '[{
    "Id":"m1",
    "MetricStat":{
      "Metric":{
        "Namespace":"AWS/Events",
        "MetricName":"TriggeredRules",
        "Dimensions":[{"Name":"RuleName","Value":"'${CORE_EVENTBRIDGE_RULE}'"}]
      },
      "Period":60,
      "Stat":"Sum"
    }
  }]' \
  --start-time "$START_TIME" \
  --end-time "$END_TIME" \
  --region "$REGION" \
  --query 'MetricDataResults[0].Values' \
  --output json | jq 'add // 0'

echo ""
echo "1b. Invocations (successful deliveries to target):"
aws_core cloudwatch get-metric-data \
  --metric-data-queries '[{
    "Id":"m1",
    "MetricStat":{
      "Metric":{
        "Namespace":"AWS/Events",
        "MetricName":"Invocations",
        "Dimensions":[{"Name":"RuleName","Value":"'${CORE_EVENTBRIDGE_RULE}'"}]
      },
      "Period":60,
      "Stat":"Sum"
    }
  }]' \
  --start-time "$START_TIME" \
  --end-time "$END_TIME" \
  --region "$REGION" \
  --query 'MetricDataResults[0].Values' \
  --output json | jq 'add // 0'

echo ""
echo "1c. FailedInvocations (failed deliveries to target):"
aws_core cloudwatch get-metric-data \
  --metric-data-queries '[{
    "Id":"m1",
    "MetricStat":{
      "Metric":{
        "Namespace":"AWS/Events",
        "MetricName":"FailedInvocations",
        "Dimensions":[{"Name":"RuleName","Value":"'${CORE_EVENTBRIDGE_RULE}'"}]
      },
      "Period":60,
      "Stat":"Sum"
    }
  }]' \
  --start-time "$START_TIME" \
  --end-time "$END_TIME" \
  --region "$REGION" \
  --query 'MetricDataResults[0].Values' \
  --output json | jq 'add // 0'

echo ""
echo "Expected: TriggeredRules > 0, Invocations > 0, FailedInvocations = 0"
echo "If TriggeredRules = 0: S3 events not reaching EventBridge or rule pattern mismatch"
echo "If FailedInvocations > 0: Cross-account delivery failing (check IAM role/permissions)"
echo ""

# Step 2: RPS Custom Event Bus Rule Metrics
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STEP 2: RPS Account Custom Event Bus Rule"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Custom Bus: $CUSTOM_EVENT_BUS"
echo "Rule: $RPS_EVENTBRIDGE_RULE"
echo ""

echo "2a. TriggeredRules (events matched on custom bus):"
aws_rps cloudwatch get-metric-data \
  --metric-data-queries '[{
    "Id":"m1",
    "MetricStat":{
      "Metric":{
        "Namespace":"AWS/Events",
        "MetricName":"TriggeredRules",
        "Dimensions":[{"Name":"RuleName","Value":"'${RPS_EVENTBRIDGE_RULE}'"}]
      },
      "Period":60,
      "Stat":"Sum"
    }
  }]' \
  --start-time "$START_TIME" \
  --end-time "$END_TIME" \
  --region "$REGION" \
  --query 'MetricDataResults[0].Values' \
  --output json | jq 'add // 0'

echo ""
echo "2b. Invocations (deliveries to SQS):"
aws_rps cloudwatch get-metric-data \
  --metric-data-queries '[{
    "Id":"m1",
    "MetricStat":{
      "Metric":{
        "Namespace":"AWS/Events",
        "MetricName":"Invocations",
        "Dimensions":[{"Name":"RuleName","Value":"'${RPS_EVENTBRIDGE_RULE}'"}]
      },
      "Period":60,
      "Stat":"Sum"
    }
  }]' \
  --start-time "$START_TIME" \
  --end-time "$END_TIME" \
  --region "$REGION" \
  --query 'MetricDataResults[0].Values' \
  --output json | jq 'add // 0'

echo ""
echo "2c. FailedInvocations (failed deliveries to SQS):"
aws_rps cloudwatch get-metric-data \
  --metric-data-queries '[{
    "Id":"m1",
    "MetricStat":{
      "Metric":{
        "Namespace":"AWS/Events",
        "MetricName":"FailedInvocations",
        "Dimensions":[{"Name":"RuleName","Value":"'${RPS_EVENTBRIDGE_RULE}'"}]
      },
      "Period":60,
      "Stat":"Sum"
    }
  }]' \
  --start-time "$START_TIME" \
  --end-time "$END_TIME" \
  --region "$REGION" \
  --query 'MetricDataResults[0].Values' \
  --output json | jq 'add // 0'

echo ""
echo "Expected: TriggeredRules > 0, Invocations > 0, FailedInvocations = 0"
echo "If TriggeredRules = 0: Events not reaching custom bus or rule pattern mismatch"
echo "If FailedInvocations > 0: SQS queue policy issue (check aws:SourceAccount condition)"
echo ""

# Step 3: SQS Queue Metrics
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STEP 3: SQS Queue"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Queue: $QUEUE_NAME"
echo ""

QUEUE_URL=$(aws_rps sqs get-queue-url \
  --queue-name "$QUEUE_NAME" \
  --region "$REGION" \
  --query 'QueueUrl' \
  --output text)

echo "3a. Current queue status:"
aws_rps sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names All \
  --region "$REGION" | jq '.Attributes | {
  MessagesAvailable: .ApproximateNumberOfMessages,
  MessagesInFlight: .ApproximateNumberOfMessagesNotVisible,
  MessagesSent: .NumberOfMessagesSent,
  MessagesReceived: .NumberOfMessagesReceived
}'

echo ""
echo "3b. NumberOfMessagesSent (last 10m):"
aws_rps cloudwatch get-metric-statistics \
  --namespace AWS/SQS \
  --metric-name NumberOfMessagesSent \
  --dimensions Name=QueueName,Value="$QUEUE_NAME" \
  --start-time "$START_TIME" \
  --end-time "$END_TIME" \
  --period 600 \
  --statistics Sum \
  --region "$REGION" \
  --query 'Datapoints[0].Sum // `0`'

echo ""
echo "3c. NumberOfMessagesReceived (last 10m):"
aws_rps cloudwatch get-metric-statistics \
  --namespace AWS/SQS \
  --metric-name NumberOfMessagesReceived \
  --dimensions Name=QueueName,Value="$QUEUE_NAME" \
  --start-time "$START_TIME" \
  --end-time "$END_TIME" \
  --period 600 \
  --statistics Sum \
  --region "$REGION" \
  --query 'Datapoints[0].Sum // `0`'

echo ""
echo "Expected: MessagesSent > 0, MessagesReceived > 0"
echo "If MessagesSent = 0: EventBridge not delivering to SQS (check Step 2 FailedInvocations)"
echo "If MessagesReceived = 0: Lambda not polling SQS (check event source mapping)"
echo ""

# Step 4: Lambda Function Metrics
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STEP 4: Lambda Processor"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Function: $LAMBDA_NAME"
echo ""

echo "4a. Invocations:"
aws_rps cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Invocations \
  --dimensions Name=FunctionName,Value="$LAMBDA_NAME" \
  --start-time "$START_TIME" \
  --end-time "$END_TIME" \
  --period 600 \
  --statistics Sum \
  --region "$REGION" \
  --query 'Datapoints[0].Sum // `0`'

echo ""
echo "4b. Errors:"
aws_rps cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Errors \
  --dimensions Name=FunctionName,Value="$LAMBDA_NAME" \
  --start-time "$START_TIME" \
  --end-time "$END_TIME" \
  --period 600 \
  --statistics Sum \
  --region "$REGION" \
  --query 'Datapoints[0].Sum // `0`'

echo ""
echo "4c. Duration (average ms):"
aws_rps cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Duration \
  --dimensions Name=FunctionName,Value="$LAMBDA_NAME" \
  --start-time "$START_TIME" \
  --end-time "$END_TIME" \
  --period 600 \
  --statistics Average \
  --region "$REGION" \
  --query 'Datapoints[0].Average // `0`'

echo ""
echo "Expected: Invocations > 0, Errors = 0"
echo "If Invocations = 0: Lambda not triggered (check event source mapping)"
echo "If Errors > 0: Lambda execution failed (check logs with: aws logs tail /aws/lambda/$LAMBDA_NAME)"
echo ""

# Summary
echo "=========================================="
echo "Flow Tracing Complete"
echo "=========================================="
echo ""
echo "Expected event flow:"
echo "  S3 → Core EventBridge Rule → RPS Custom Bus → RPS EventBridge Rule → SQS → Lambda → S3"
echo ""
echo "Use these scripts for detailed checks:"
echo "  debug/02-check-core.sh       - Core account resources"
echo "  debug/03-check-rps.sh        - RPS account resources"
echo "  debug/04-test-upload.sh      - Upload test file and monitor"
echo "  debug/05-check-policies.sh   - Verify IAM/resource policies"
echo ""
