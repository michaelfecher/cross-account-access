#!/usr/bin/env bash
#
# Check RPS Account resources and configuration
#
# Usage:
#   bash debug/04-check-rps.sh

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the configuration
source "$SCRIPT_DIR/00-config.sh"

echo "=========================================="
echo "RPS Account Resources Check"
echo "=========================================="
echo ""

# Track overall status
FAILED=0

# ============================================
# CHECK 1: Custom Event Bus Exists
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CHECK 1: Custom Event Bus"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Bus: $CUSTOM_EVENT_BUS"
echo ""

BUS_ARN=$(aws_rps events describe-event-bus \
  --name "$CUSTOM_EVENT_BUS" \
  --region "$REGION" 2>/dev/null | jq -r '.Arn // empty')

if [ -n "$BUS_ARN" ]; then
  echo "✅ PASS: Event bus exists"
  echo "  ARN: $BUS_ARN"
else
  echo "❌ FAIL: Event bus does not exist"
  echo ""
  echo "SOLUTION: Redeploy RPS Stack"
  echo "  cdk deploy ${STAGE}-StackRps --profile ${RPS_PROFILE:-rps-account}"
  FAILED=1
fi
echo ""

# ============================================
# CHECK 2: Event Bus Policy
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CHECK 2: Event Bus Policy - Core Account Access"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

BUS_POLICY=$(aws_rps events describe-event-bus \
  --name "$CUSTOM_EVENT_BUS" \
  --region "$REGION" 2>/dev/null | jq -r '.Policy // empty')

if [ -n "$BUS_POLICY" ]; then
  PRINCIPAL=$(echo "$BUS_POLICY" | jq -r '.Statement[0].Principal.AWS // empty')
  ACTION=$(echo "$BUS_POLICY" | jq -r '.Statement[0].Action // empty')

  if echo "$PRINCIPAL" | grep -q "$CORE_ACCOUNT_ID" && [ "$ACTION" = "events:PutEvents" ]; then
    echo "✅ PASS: Core account can PutEvents to custom bus"
    echo "  Principal: $PRINCIPAL"
  else
    echo "❌ FAIL: Bus policy incorrect"
    echo "  Principal: $PRINCIPAL (expected: $CORE_ACCOUNT_ID)"
    echo "  Action: $ACTION (expected: events:PutEvents)"
    FAILED=1
  fi
else
  echo "❌ FAIL: No event bus policy found"
  echo ""
  echo "SOLUTION: Redeploy RPS Stack"
  echo "  cdk deploy ${STAGE}-StackRps --profile ${RPS_PROFILE:-rps-account}"
  FAILED=1
fi
echo ""

# ============================================
# CHECK 3: EventBridge Rule State
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CHECK 3: EventBridge Rule State"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Rule: $RPS_EVENTBRIDGE_RULE"
echo ""

RULE_STATE=$(aws_rps events describe-rule \
  --name "$RPS_EVENTBRIDGE_RULE" \
  --event-bus-name "$CUSTOM_EVENT_BUS" \
  --region "$REGION" 2>/dev/null | jq -r '.State // empty')

if [ "$RULE_STATE" = "ENABLED" ]; then
  echo "✅ PASS: Rule is ENABLED"
else
  echo "❌ FAIL: Rule state is '$RULE_STATE' (expected ENABLED)"
  echo ""
  echo "SOLUTION: Redeploy RPS Stack"
  echo "  cdk deploy ${STAGE}-StackRps --profile ${RPS_PROFILE:-rps-account}"
  FAILED=1
fi
echo ""

# ============================================
# CHECK 4: EventBridge Rule Event Pattern
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CHECK 4: EventBridge Rule Event Pattern"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

EVENT_PATTERN=$(aws_rps events describe-rule \
  --name "$RPS_EVENTBRIDGE_RULE" \
  --event-bus-name "$CUSTOM_EVENT_BUS" \
  --region "$REGION" 2>/dev/null | jq -r '.EventPattern // empty')

ACCOUNT=$(echo "$EVENT_PATTERN" | jq -r '.account[0] // empty')
SOURCE=$(echo "$EVENT_PATTERN" | jq -r '.source[0] // empty')
DETAIL_TYPE=$(echo "$EVENT_PATTERN" | jq -r '."detail-type"[0] // empty')
BUCKET_CHECK=$(echo "$EVENT_PATTERN" | jq -r '.detail.bucket.name[0] // empty')

if [ "$ACCOUNT" = "$CORE_ACCOUNT_ID" ] && [ "$SOURCE" = "aws.s3" ] && \
   [ "$DETAIL_TYPE" = "Object Created" ] && [ "$BUCKET_CHECK" = "$INPUT_BUCKET_NAME" ]; then
  echo "✅ PASS: Event pattern filters for input bucket events"
  echo "  Account: $ACCOUNT"
  echo "  Source: $SOURCE"
  echo "  DetailType: $DETAIL_TYPE"
  echo "  Bucket: $BUCKET_CHECK"
else
  echo "❌ FAIL: Event pattern incorrect"
  echo "  Account: $ACCOUNT (expected: $CORE_ACCOUNT_ID)"
  echo "  Source: $SOURCE (expected: aws.s3)"
  echo "  DetailType: $DETAIL_TYPE (expected: Object Created)"
  echo "  Bucket: $BUCKET_CHECK (expected: $INPUT_BUCKET_NAME)"
  FAILED=1
fi
echo ""

# ============================================
# CHECK 5: EventBridge Rule Target
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CHECK 5: EventBridge Rule Target - SQS Queue"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

EXPECTED_QUEUE_ARN="arn:aws:sqs:${REGION}:${RPS_ACCOUNT_ID}:${QUEUE_NAME}"
ACTUAL_TARGET=$(aws_rps events list-targets-by-rule \
  --rule "$RPS_EVENTBRIDGE_RULE" \
  --event-bus-name "$CUSTOM_EVENT_BUS" \
  --region "$REGION" 2>/dev/null | jq -r '.Targets[0].Arn // empty')

if [ "$ACTUAL_TARGET" = "$EXPECTED_QUEUE_ARN" ]; then
  echo "✅ PASS: Target is SQS processor queue"
  echo "  Target: $ACTUAL_TARGET"
else
  echo "❌ FAIL: Target ARN mismatch"
  echo "  Expected: $EXPECTED_QUEUE_ARN"
  echo "  Actual:   $ACTUAL_TARGET"
  FAILED=1
fi
echo ""

# ============================================
# CHECK 6: SQS Queue Exists
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CHECK 6: SQS Queue Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Queue: $QUEUE_NAME"
echo ""

QUEUE_URL=$(aws_rps sqs get-queue-url \
  --queue-name "$QUEUE_NAME" \
  --region "$REGION" 2>/dev/null | jq -r '.QueueUrl // empty')

if [ -n "$QUEUE_URL" ]; then
  echo "✅ PASS: Queue exists"
  echo "  URL: $QUEUE_URL"

  # Check KMS encryption
  KMS_KEY=$(aws_rps sqs get-queue-attributes \
    --queue-url "$QUEUE_URL" \
    --attribute-names KmsMasterKeyId \
    --region "$REGION" 2>/dev/null | jq -r '.Attributes.KmsMasterKeyId // empty')

  if [ -n "$KMS_KEY" ]; then
    echo "✅ PASS: Queue encrypted with KMS"
  else
    echo "❌ FAIL: Queue not encrypted with KMS"
    FAILED=1
  fi
else
  echo "❌ FAIL: Queue does not exist"
  echo ""
  echo "SOLUTION: Redeploy RPS Stack"
  echo "  cdk deploy ${STAGE}-StackRps --profile ${RPS_PROFILE:-rps-account}"
  FAILED=1
fi
echo ""

# ============================================
# CHECK 7: SQS Queue Policy (CRITICAL)
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CHECK 7: SQS Queue Policy - EventBridge Access"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "⚠️  CRITICAL: Must use aws:SourceArn, NOT aws:SourceAccount"
echo ""

if [ -n "$QUEUE_URL" ]; then
  QUEUE_POLICY=$(aws_rps sqs get-queue-attributes \
    --queue-url "$QUEUE_URL" \
    --attribute-names Policy \
    --region "$REGION" 2>/dev/null | jq -r '.Attributes.Policy // empty')

  EB_STATEMENT=$(echo "$QUEUE_POLICY" | jq -r '.Statement[] | select(.Sid == "AllowEventBridgeRuleSendMessage") // empty')

  if [ -n "$EB_STATEMENT" ]; then
    # Check for wrong condition (aws:SourceAccount)
    SOURCE_ACCOUNT=$(echo "$EB_STATEMENT" | jq -r '.Condition.StringEquals["aws:SourceAccount"] // empty')

    if [ -n "$SOURCE_ACCOUNT" ]; then
      echo "❌ FAIL: Queue policy uses aws:SourceAccount (blocks cross-account events!)"
      echo "  Condition: aws:SourceAccount = $SOURCE_ACCOUNT"
      echo ""
      echo "SOLUTION: Redeploy RPS Stack to fix the policy"
      echo "  cdk deploy ${STAGE}-StackRps --profile ${RPS_PROFILE:-rps-account}"
      FAILED=1
    else
      # Check for correct condition (aws:SourceArn)
      SOURCE_ARN=$(echo "$EB_STATEMENT" | jq -r '.Condition.ArnEquals["aws:SourceArn"] // empty')

      if [ -n "$SOURCE_ARN" ]; then
        echo "✅ PASS: Queue policy uses aws:SourceArn (correct)"
        echo "  Condition: aws:SourceArn = $SOURCE_ARN"
      else
        echo "❌ FAIL: Queue policy missing aws:SourceArn condition"
        FAILED=1
      fi
    fi
  else
    echo "❌ FAIL: Missing 'AllowEventBridgeRuleSendMessage' statement"
    FAILED=1
  fi
fi
echo ""

# ============================================
# CHECK 8: Lambda Function Exists
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CHECK 8: Lambda Function"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Function: $LAMBDA_NAME"
echo ""

LAMBDA_ARN=$(aws_rps lambda get-function \
  --function-name "$LAMBDA_NAME" \
  --region "$REGION" 2>/dev/null | jq -r '.Configuration.FunctionArn // empty')

if [ -n "$LAMBDA_ARN" ]; then
  echo "✅ PASS: Lambda function exists"
  echo "  ARN: $LAMBDA_ARN"
else
  echo "❌ FAIL: Lambda function does not exist"
  echo ""
  echo "SOLUTION: Redeploy RPS Stack"
  echo "  cdk deploy ${STAGE}-StackRps --profile ${RPS_PROFILE:-rps-account}"
  FAILED=1
fi
echo ""

# ============================================
# CHECK 9: Lambda Event Source Mapping
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CHECK 9: Lambda Event Source Mapping - SQS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

ESM_STATE=$(aws_rps lambda list-event-source-mappings \
  --function-name "$LAMBDA_NAME" \
  --region "$REGION" 2>/dev/null | jq -r '.EventSourceMappings[0].State // empty')

ESM_SOURCE=$(aws_rps lambda list-event-source-mappings \
  --function-name "$LAMBDA_NAME" \
  --region "$REGION" 2>/dev/null | jq -r '.EventSourceMappings[0].EventSourceArn // empty')

if [ "$ESM_STATE" = "Enabled" ]; then
  echo "✅ PASS: Event source mapping is Enabled"
  echo "  State: $ESM_STATE"
  echo "  Source: $ESM_SOURCE"
else
  echo "❌ FAIL: Event source mapping state is '$ESM_STATE' (expected Enabled)"
  echo "  Source: $ESM_SOURCE"
  FAILED=1
fi
echo ""

# ============================================
# CHECK 10: Lambda S3 Read Permissions
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CHECK 10: Lambda IAM Role - S3 Read Permissions"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

LAMBDA_ROLE_ARN=$(aws_rps lambda get-function \
  --function-name "$LAMBDA_NAME" \
  --region "$REGION" 2>/dev/null | jq -r '.Configuration.Role // empty')

ROLE_NAME=$(echo "$LAMBDA_ROLE_ARN" | cut -d'/' -f2)
echo "Role: $ROLE_NAME"
echo ""

# Get all inline policies
ALL_POLICIES=$(aws_rps iam list-role-policies \
  --role-name "$ROLE_NAME" 2>/dev/null | jq -r '.PolicyNames[]')

S3_READ_FOUND=false
for policy in $ALL_POLICIES; do
  POLICY_DOC=$(aws_rps iam get-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "$policy" 2>/dev/null | jq -r '.PolicyDocument')

  # Check for S3 read statement
  READ_SID=$(echo "$POLICY_DOC" | jq -r '.Statement[] | select(.Sid == "ReadFromStackCoreBucket") | .Sid')

  if [ "$READ_SID" = "ReadFromStackCoreBucket" ]; then
    S3_READ_FOUND=true

    # Verify input bucket name in resources (handle both string and array)
    RESOURCE_CHECK=$(echo "$POLICY_DOC" | jq -r ".Statement[] | select(.Sid == \"ReadFromStackCoreBucket\") | .Resource | if type == \"array\" then .[] else . end | select(contains(\"$INPUT_BUCKET_NAME\"))")

    if [ -n "$RESOURCE_CHECK" ]; then
      echo "✅ PASS: Lambda can read from Core input bucket"
      echo "  Bucket: $INPUT_BUCKET_NAME"
    else
      echo "❌ FAIL: S3 read policy exists but wrong bucket"
      FAILED=1
    fi
    break
  fi
done

if [ "$S3_READ_FOUND" = false ]; then
  echo "❌ FAIL: Missing S3 read permissions for Core input bucket"
  echo ""
  echo "SOLUTION: Redeploy RPS Stack"
  echo "  cdk deploy ${STAGE}-StackRps --profile ${RPS_PROFILE:-rps-account}"
  FAILED=1
fi
echo ""

# ============================================
# CHECK 11: Lambda S3 Write Permissions
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CHECK 11: Lambda IAM Role - S3 Write Permissions"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

S3_WRITE_FOUND=false
for policy in $ALL_POLICIES; do
  POLICY_DOC=$(aws_rps iam get-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "$policy" 2>/dev/null | jq -r '.PolicyDocument')

  WRITE_SID=$(echo "$POLICY_DOC" | jq -r '.Statement[] | select(.Sid == "WriteToStackCoreBucket") | .Sid')

  if [ "$WRITE_SID" = "WriteToStackCoreBucket" ]; then
    S3_WRITE_FOUND=true

    # Verify output bucket name in resources (handle both string and array)
    RESOURCE_CHECK=$(echo "$POLICY_DOC" | jq -r ".Statement[] | select(.Sid == \"WriteToStackCoreBucket\") | .Resource | if type == \"array\" then .[] else . end | select(contains(\"$OUTPUT_BUCKET_NAME\"))")

    if [ -n "$RESOURCE_CHECK" ]; then
      echo "✅ PASS: Lambda can write to Core output bucket"
      echo "  Bucket: $OUTPUT_BUCKET_NAME"
    else
      echo "❌ FAIL: S3 write policy exists but wrong bucket"
      FAILED=1
    fi
    break
  fi
done

if [ "$S3_WRITE_FOUND" = false ]; then
  echo "❌ FAIL: Missing S3 write permissions for Core output bucket"
  echo ""
  echo "SOLUTION: Redeploy RPS Stack"
  echo "  cdk deploy ${STAGE}-StackRps --profile ${RPS_PROFILE:-rps-account}"
  FAILED=1
fi
echo ""

# ============================================
# CHECK 12: Lambda KMS Permissions
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CHECK 12: Lambda IAM Role - KMS Decrypt Permissions"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

KMS_FOUND=false
for policy in $ALL_POLICIES; do
  POLICY_DOC=$(aws_rps iam get-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "$policy" 2>/dev/null | jq -r '.PolicyDocument')

  KMS_SID=$(echo "$POLICY_DOC" | jq -r '.Statement[] | select(.Sid == "DecryptStackCoreBucket") | .Sid')

  if [ "$KMS_SID" = "DecryptStackCoreBucket" ]; then
    KMS_FOUND=true

    # Check for kms:ViaService condition
    VIA_SERVICE=$(echo "$POLICY_DOC" | jq -r '.Statement[] | select(.Sid == "DecryptStackCoreBucket") | .Condition.StringEquals["kms:ViaService"] // empty')

    if [ "$VIA_SERVICE" = "s3.${REGION}.amazonaws.com" ]; then
      echo "✅ PASS: Lambda can decrypt Core account KMS keys via S3"
      echo "  Condition: kms:ViaService = $VIA_SERVICE"
    else
      echo "❌ FAIL: KMS policy missing kms:ViaService condition"
      FAILED=1
    fi
    break
  fi
done

if [ "$KMS_FOUND" = false ]; then
  echo "❌ FAIL: Missing KMS decrypt permissions"
  FAILED=1
fi
echo ""

# ============================================
# CHECK 13: Dead Letter Queue
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CHECK 13: Dead Letter Queue"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
DLQ_NAME="${STAGE}-processor-dlq"
echo "DLQ: $DLQ_NAME"
echo ""

DLQ_URL=$(aws_rps sqs get-queue-url \
  --queue-name "$DLQ_NAME" \
  --region "$REGION" 2>/dev/null | jq -r '.QueueUrl // empty')

if [ -n "$DLQ_URL" ]; then
  echo "✅ PASS: DLQ exists"
  echo "  URL: $DLQ_URL"

  # Check message count
  MSG_COUNT=$(aws_rps sqs get-queue-attributes \
    --queue-url "$DLQ_URL" \
    --attribute-names ApproximateNumberOfMessages \
    --region "$REGION" 2>/dev/null | jq -r '.Attributes.ApproximateNumberOfMessages // "0"')

  if [ "$MSG_COUNT" -gt 0 ]; then
    echo "⚠️  WARNING: DLQ has $MSG_COUNT messages"
    echo "  Lambda failed to process messages 3+ times"
    echo "  Check Lambda logs for errors"
  else
    echo "✅ DLQ is empty (no failed messages)"
  fi
else
  echo "❌ FAIL: DLQ does not exist"
  FAILED=1
fi
echo ""

# ============================================
# Summary
# ============================================
echo "=========================================="
if [ $FAILED -eq 0 ]; then
  echo "✅ ALL CHECKS PASSED"
  echo "RPS Account is properly configured"
else
  echo "❌ SOME CHECKS FAILED"
  echo "Review errors above and redeploy as needed"
  echo "=========================================="
  exit 1
fi
echo "=========================================="
