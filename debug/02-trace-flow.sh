#!/usr/bin/env bash
#
# End-to-end flow tracing for cross-account event delivery
# Checks metrics at each step to identify where events are getting stuck
#
# Usage:
#   bash debug/02-trace-flow.sh
#
# Or with custom config:
#   export CDK_DEPLOYMENT_PREFIX=dev CORE_ACCOUNT_ID=... RPS_ACCOUNT_ID=...
#   bash debug/02-trace-flow.sh

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the configuration
source "$SCRIPT_DIR/00-config.sh"

echo "=========================================="
echo "Cross-Account Event Flow Tracing"
echo "=========================================="
echo ""
echo "⚠️  WARNING: CloudWatch metrics can be delayed by 5-15 minutes!"
echo ""
echo "BEFORE checking metrics, verify the actual result first:"
echo "  1. Check if output file exists in S3:"
echo "     aws s3 ls s3://${BUCKET_NAME}/output/ --profile \${CORE_PROFILE}"
echo ""
echo "  2. If output file exists → System is working! Ignore metric delays."
echo "  3. If output missing → Continue with this metric trace to diagnose."
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Checking CloudWatch metrics for the last 10 minutes..."
echo "(Metrics may not appear immediately after upload)"
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

# Track overall status
ALL_PASSED=true

# Step 1: Core EventBridge Rule Metrics
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STEP 1: Core Account EventBridge Rule"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Rule: $CORE_EVENTBRIDGE_RULE"
echo ""

# Get TriggeredRules
STEP1_TRIGGERED=$(aws_core cloudwatch get-metric-data \
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
  --output json 2>/dev/null | jq 'add // 0')

# Get Invocations
STEP1_INVOCATIONS=$(aws_core cloudwatch get-metric-data \
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
  --output json 2>/dev/null | jq 'add // 0')

# Get FailedInvocations
STEP1_FAILED=$(aws_core cloudwatch get-metric-data \
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
  --output json 2>/dev/null | jq 'add // 0')

echo "TriggeredRules:    $STEP1_TRIGGERED"
echo "Invocations:       $STEP1_INVOCATIONS"
echo "FailedInvocations: $STEP1_FAILED"
echo ""

# Check Step 1 status
if (( $(echo "$STEP1_TRIGGERED > 0" | bc -l) )); then
  if (( $(echo "$STEP1_INVOCATIONS > 0" | bc -l) )) && (( $(echo "$STEP1_FAILED == 0" | bc -l) )); then
    echo "✅ STEP 1 PASSED: Core EventBridge rule triggered and delivered events"
  elif (( $(echo "$STEP1_FAILED > 0" | bc -l) )); then
    echo "❌ STEP 1 FAILED: Events triggered but failed to deliver to RPS custom bus"
    echo ""
    echo "PROBLEM: FailedInvocations = $STEP1_FAILED"
    echo ""
    echo "This means the Core EventBridge rule matched S3 events but couldn't send them"
    echo "to the RPS account's custom event bus."
    echo ""
    echo "NEXT STEPS:"
    echo "  1. Check Core EventBridge IAM role has events:PutEvents permission:"
    echo "     bash debug/03-check-core.sh"
    echo "  2. Check RPS custom event bus policy allows Core account:"
    echo "     bash debug/04-check-rps.sh"
    echo ""
    exit 1
  else
    echo "⚠️  STEP 1 PARTIAL: Rule triggered but no successful invocations"
    ALL_PASSED=false
  fi
else
  echo "❌ STEP 1 FAILED: Core EventBridge rule not triggered"
  echo ""
  echo "PROBLEM: No S3 events reached the Core EventBridge rule"
  echo ""
  echo "POSSIBLE CAUSES:"
  echo "  1. S3 bucket doesn't have EventBridge notifications enabled"
  echo "  2. No files uploaded to ${INPUT_PREFIX} prefix in the last 10 minutes"
  echo "  3. EventBridge rule pattern doesn't match S3 events"
  echo ""
  echo "NEXT STEPS:"
  echo "  1. Upload a test file: bash debug/01-test-upload.sh"
  echo "  2. Check Core account configuration: bash debug/03-check-core.sh"
  echo ""
  exit 1
fi
echo ""

# Step 2: RPS Custom Event Bus Rule Metrics
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STEP 2: RPS Account Custom Event Bus Rule"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Custom Bus: $CUSTOM_EVENT_BUS"
echo "Rule: $RPS_EVENTBRIDGE_RULE"
echo ""

# Get TriggeredRules
STEP2_TRIGGERED=$(aws_rps cloudwatch get-metric-data \
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
  --output json 2>/dev/null | jq 'add // 0')

# Get Invocations
STEP2_INVOCATIONS=$(aws_rps cloudwatch get-metric-data \
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
  --output json 2>/dev/null | jq 'add // 0')

# Get FailedInvocations
STEP2_FAILED=$(aws_rps cloudwatch get-metric-data \
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
  --output json 2>/dev/null | jq 'add // 0')

echo "TriggeredRules:    $STEP2_TRIGGERED"
echo "Invocations:       $STEP2_INVOCATIONS"
echo "FailedInvocations: $STEP2_FAILED"
echo ""

# Check Step 2 status
if (( $(echo "$STEP2_TRIGGERED > 0" | bc -l) )); then
  if (( $(echo "$STEP2_INVOCATIONS > 0" | bc -l) )) && (( $(echo "$STEP2_FAILED == 0" | bc -l) )); then
    echo "✅ STEP 2 PASSED: RPS EventBridge rule triggered and delivered to SQS"
  elif (( $(echo "$STEP2_FAILED > 0" | bc -l) )); then
    echo "❌ STEP 2 FAILED: Events triggered but failed to deliver to SQS"
    echo ""
    echo "PROBLEM: FailedInvocations = $STEP2_FAILED"
    echo ""
    echo "This is the MOST COMMON issue - SQS queue policy blocking EventBridge!"
    echo ""
    echo "SOLUTION: Redeploy the RPS stack to apply the correct SQS policy:"
    echo "  cdk deploy ${CDK_DEPLOYMENT_PREFIX}-StackRps --profile ${RPS_PROFILE:-rps-account}"
    echo ""
    echo "The code already has the fix (uses aws:SourceArn), but if you deployed"
    echo "before this fix, the queue still has the old policy."
    echo ""
    echo "To verify the policy is correct:"
    echo "  bash debug/04-check-rps.sh"
    echo "  (Look for section '3b. Queue policy' - should show aws:SourceArn)"
    echo ""
    exit 1
  else
    echo "⚠️  STEP 2 PARTIAL: Rule triggered but no successful invocations"
    ALL_PASSED=false
  fi
else
  echo "❌ STEP 2 FAILED: RPS EventBridge rule not triggered"
  echo ""
  echo "PROBLEM: No events from Core account reached RPS custom event bus"
  echo ""
  echo "POSSIBLE CAUSES:"
  echo "  1. Events not arriving at RPS custom bus (check Step 1 passed)"
  echo "  2. RPS EventBridge rule pattern doesn't match incoming events"
  echo "  3. RPS custom event bus policy doesn't allow Core account"
  echo ""
  echo "NEXT STEPS:"
  echo "  1. Verify RPS event bus configuration: bash debug/04-check-rps.sh"
  echo "  2. Check event bus policy allows Core account: bash debug/05-check-policies.sh"
  echo ""
  exit 1
fi
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
  --output text 2>/dev/null)

# Get current queue stats
QUEUE_STATS=$(aws_rps sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names ApproximateNumberOfMessages,NumberOfMessagesSent,NumberOfMessagesReceived \
  --region "$REGION" 2>/dev/null)

MESSAGES_AVAILABLE=$(echo "$QUEUE_STATS" | jq -r '.Attributes.ApproximateNumberOfMessages // "0"')
MESSAGES_SENT=$(echo "$QUEUE_STATS" | jq -r '.Attributes.NumberOfMessagesSent // "0"')
MESSAGES_RECEIVED=$(echo "$QUEUE_STATS" | jq -r '.Attributes.NumberOfMessagesReceived // "0"')

echo "Messages available: $MESSAGES_AVAILABLE"
echo "Messages sent:      $MESSAGES_SENT"
echo "Messages received:  $MESSAGES_RECEIVED"
echo ""

# Check Step 3 status
if (( MESSAGES_SENT > 0 )); then
  if (( MESSAGES_RECEIVED > 0 )); then
    echo "✅ STEP 3 PASSED: SQS received and delivered messages to Lambda"
  else
    echo "❌ STEP 3 FAILED: Messages sent to SQS but not received by Lambda"
    echo ""
    echo "PROBLEM: Lambda not polling SQS queue"
    echo ""
    echo "POSSIBLE CAUSES:"
    echo "  1. Lambda event source mapping disabled or misconfigured"
    echo "  2. Lambda doesn't have permission to read from SQS"
    echo "  3. Messages stuck in queue (${MESSAGES_AVAILABLE} available)"
    echo ""
    echo "NEXT STEPS:"
    echo "  1. Check Lambda event source mapping: bash debug/04-check-rps.sh"
    echo "  2. Check Lambda logs: aws logs tail /aws/lambda/$LAMBDA_NAME --follow --region $REGION --profile ${RPS_PROFILE:-default}"
    echo ""
    exit 1
  fi
else
  echo "❌ STEP 3 FAILED: No messages sent to SQS queue"
  echo ""
  echo "PROBLEM: EventBridge delivered events but SQS received nothing"
  echo ""
  echo "This confirms Step 2 failure - check SQS queue policy!"
  echo ""
  echo "NEXT STEPS:"
  echo "  1. Check SQS queue policy: bash debug/04-check-rps.sh"
  echo "  2. Look for section '3b. Queue policy (IMPORTANT - check for SourceAccount issue)'"
  echo ""
  exit 1
fi
echo ""

# Step 4: Lambda Function Metrics
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "STEP 4: Lambda Processor"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Function: $LAMBDA_NAME"
echo ""

# Get Lambda invocations
STEP4_INVOCATIONS=$(aws_rps cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Invocations \
  --dimensions Name=FunctionName,Value="$LAMBDA_NAME" \
  --start-time "$START_TIME" \
  --end-time "$END_TIME" \
  --period 600 \
  --statistics Sum \
  --region "$REGION" \
  --query 'Datapoints[0].Sum' \
  --output text 2>/dev/null)

STEP4_INVOCATIONS=${STEP4_INVOCATIONS:-0}
if [ "$STEP4_INVOCATIONS" = "None" ]; then
  STEP4_INVOCATIONS=0
fi

# Get Lambda errors
STEP4_ERRORS=$(aws_rps cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Errors \
  --dimensions Name=FunctionName,Value="$LAMBDA_NAME" \
  --start-time "$START_TIME" \
  --end-time "$END_TIME" \
  --period 600 \
  --statistics Sum \
  --region "$REGION" \
  --query 'Datapoints[0].Sum' \
  --output text 2>/dev/null)

STEP4_ERRORS=${STEP4_ERRORS:-0}
if [ "$STEP4_ERRORS" = "None" ]; then
  STEP4_ERRORS=0
fi

echo "Invocations: $STEP4_INVOCATIONS"
echo "Errors:      $STEP4_ERRORS"
echo ""

# Check Step 4 status
if (( $(echo "$STEP4_INVOCATIONS > 0" | bc -l) )); then
  if (( $(echo "$STEP4_ERRORS == 0" | bc -l) )); then
    echo "✅ STEP 4 PASSED: Lambda executed successfully"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ ALL STEPS PASSED!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "The end-to-end flow is working correctly:"
    echo "  S3 → Core EventBridge → RPS Custom Bus → SQS → Lambda → S3"
    echo ""
    echo "If output file still not created, check:"
    echo "  1. Lambda has permission to write to s3://$BUCKET_NAME/output/"
    echo "  2. Lambda logs for errors: aws logs tail /aws/lambda/$LAMBDA_NAME --region $REGION --profile ${RPS_PROFILE:-default}"
    echo "  3. Core S3 bucket policy: bash debug/05-check-policies.sh"
    echo ""
  else
    echo "❌ STEP 4 FAILED: Lambda executed but had errors"
    echo ""
    echo "PROBLEM: Lambda invoked ${STEP4_INVOCATIONS} times with ${STEP4_ERRORS} errors"
    echo ""
    echo "POSSIBLE CAUSES:"
    echo "  1. Lambda can't read from Core S3 bucket (permission denied)"
    echo "  2. Lambda can't write to Core S3 bucket output/ (permission denied)"
    echo "  3. Lambda code error"
    echo ""
    echo "NEXT STEPS:"
    echo "  1. Check Lambda logs:"
    echo "     aws logs tail /aws/lambda/$LAMBDA_NAME --since 10m --region $REGION --profile ${RPS_PROFILE:-default}"
    echo "  2. Verify cross-account permissions: bash debug/05-check-policies.sh"
    echo ""
    exit 1
  fi
else
  echo "❌ STEP 4 FAILED: Lambda not invoked"
  echo ""
  echo "PROBLEM: Lambda never received any events from SQS"
  echo ""
  echo "This shouldn't happen if Step 3 passed. Possible race condition."
  echo ""
  echo "NEXT STEPS:"
  echo "  1. Wait 1 minute and run this trace again"
  echo "  2. Check Lambda event source mapping: bash debug/04-check-rps.sh"
  echo ""
  exit 1
fi

echo "=========================================="
echo "Flow Tracing Complete"
echo "=========================================="
