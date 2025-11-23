#!/usr/bin/env bash
#
# Verify all cross-account IAM and resource policies
#
# Usage:
#   bash debug/05-check-policies.sh

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the configuration
source "$SCRIPT_DIR/00-config.sh"

echo "=========================================="
echo "Cross-Account Policy Verification"
echo "=========================================="
echo ""

# Core S3 Bucket Policy
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "1. Core S3 Bucket Policy"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Checking if RPS Lambda can access Core S3 bucket..."
echo ""

BUCKET_POLICY=$(aws_core s3api get-bucket-policy \
  --bucket "$BUCKET_NAME" \
  --query 'Policy' \
  --output text)

echo "Checking for: AllowAccountRpsLambdaRead"
if echo "$BUCKET_POLICY" | jq -e '.Statement[] | select(.Sid == "AllowAccountRpsLambdaRead")' >/dev/null 2>&1; then
  echo "✓ Found AllowAccountRpsLambdaRead statement"
  echo "$BUCKET_POLICY" | jq '.Statement[] | select(.Sid == "AllowAccountRpsLambdaRead") | {
    Actions: .Action,
    Resources: .Resource,
    Principal: .Principal,
    Condition: .Condition
  }'
else
  echo "✗ MISSING: AllowAccountRpsLambdaRead statement"
fi

echo ""
echo "Checking for: AllowAccountRpsLambdaWrite"
if echo "$BUCKET_POLICY" | jq -e '.Statement[] | select(.Sid == "AllowAccountRpsLambdaWrite")' >/dev/null 2>&1; then
  echo "✓ Found AllowAccountRpsLambdaWrite statement"
  echo "$BUCKET_POLICY" | jq '.Statement[] | select(.Sid == "AllowAccountRpsLambdaWrite") | {
    Actions: .Action,
    Resources: .Resource,
    Principal: .Principal,
    Condition: .Condition
  }'
else
  echo "✗ MISSING: AllowAccountRpsLambdaWrite statement"
fi

echo ""
echo "Expected principal pattern: arn:aws:iam::${RPS_ACCOUNT_ID}:role/*-processor-lambda-role"
echo ""

# Core KMS Key Policy
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "2. Core KMS Key Policy"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Checking if RPS Lambda can decrypt/encrypt with Core KMS key..."
echo ""

KEY_ID=$(aws_core s3api get-bucket-encryption \
  --bucket "$BUCKET_NAME" \
  --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.KMSMasterKeyID' \
  --output text 2>/dev/null || echo "None")

if [ "$KEY_ID" != "None" ] && [ -n "$KEY_ID" ]; then
  echo "KMS Key: $KEY_ID"
  echo ""

  KMS_POLICY=$(aws_core kms get-key-policy \
    --key-id "$KEY_ID" \
    --policy-name default \
    --query 'Policy' \
    --output text)

  if echo "$KMS_POLICY" | jq -e '.Statement[] | select(.Sid == "AllowAccountRpsLambdaDecrypt")' >/dev/null 2>&1; then
    echo "✓ Found AllowAccountRpsLambdaDecrypt statement"
    echo "$KMS_POLICY" | jq '.Statement[] | select(.Sid == "AllowAccountRpsLambdaDecrypt") | {
      Actions: .Action,
      Principal: .Principal,
      Condition: .Condition
    }'
    echo ""
    echo "Verifying conditions:"

    # Check kms:ViaService condition
    if echo "$KMS_POLICY" | jq -e '.Statement[] | select(.Sid == "AllowAccountRpsLambdaDecrypt") | .Condition.StringEquals."kms:ViaService"' | grep -q "s3.${REGION}.amazonaws.com"; then
      echo "  ✓ kms:ViaService restricted to S3"
    else
      echo "  ✗ kms:ViaService condition missing or incorrect"
    fi

    # Check principal ARN pattern
    if echo "$KMS_POLICY" | jq -e '.Statement[] | select(.Sid == "AllowAccountRpsLambdaDecrypt") | .Condition.StringLike."aws:PrincipalArn"' | grep -q "*-processor-lambda-role"; then
      echo "  ✓ Principal ARN pattern matches Lambda role"
    else
      echo "  ✗ Principal ARN pattern missing or incorrect"
    fi
  else
    echo "✗ MISSING: AllowAccountRpsLambdaDecrypt statement"
    echo "  This will prevent Lambda from reading encrypted S3 objects"
  fi
else
  echo "ℹ No KMS encryption configured (using default S3 encryption)"
fi
echo ""

# RPS Custom Event Bus Policy
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "3. RPS Custom Event Bus Policy"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Checking if Core account can send events to RPS custom bus..."
echo ""

BUS_POLICY=$(aws_rps events describe-event-bus \
  --name "$CUSTOM_EVENT_BUS" \
  --region "$REGION" \
  --query 'Policy' \
  --output text 2>/dev/null || echo "{}")

if echo "$BUS_POLICY" | jq -e '.Statement[] | select(.Sid | contains("AllowCoreAccount"))' >/dev/null 2>&1; then
  echo "✓ Found AllowCoreAccount statement"
  echo "$BUS_POLICY" | jq '.Statement[] | select(.Sid | contains("AllowCoreAccount")) | {
    Sid: .Sid,
    Effect: .Effect,
    Principal: .Principal,
    Action: .Action,
    Resource: .Resource
  }'
  echo ""

  # Verify principal
  if echo "$BUS_POLICY" | jq -e ".Statement[] | select(.Sid | contains(\"AllowCoreAccount\")) | .Principal.AWS" | grep -q "$CORE_ACCOUNT_ID"; then
    echo "  ✓ Core account ($CORE_ACCOUNT_ID) is allowed"
  else
    echo "  ✗ Core account principal missing or incorrect"
  fi

  # Verify action
  if echo "$BUS_POLICY" | jq -e '.Statement[] | select(.Sid | contains("AllowCoreAccount")) | .Action' | grep -q "events:PutEvents"; then
    echo "  ✓ events:PutEvents action is allowed"
  else
    echo "  ✗ events:PutEvents action missing"
  fi
else
  echo "✗ MISSING: AllowCoreAccount statement"
  echo "  Core account cannot send events to custom bus"
fi
echo ""

# RPS SQS Queue Policy
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "4. RPS SQS Queue Policy"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Checking if EventBridge can send messages to SQS..."
echo ""

QUEUE_URL=$(aws_rps sqs get-queue-url \
  --queue-name "$QUEUE_NAME" \
  --region "$REGION" \
  --query 'QueueUrl' \
  --output text)

QUEUE_POLICY=$(aws_rps sqs get-queue-attributes \
  --queue-url "$QUEUE_URL" \
  --attribute-names Policy \
  --region "$REGION" \
  --query 'Attributes.Policy' \
  --output text)

if echo "$QUEUE_POLICY" | jq -e '.Statement[] | select(.Sid == "AllowEventBridgeRuleSendMessage")' >/dev/null 2>&1; then
  echo "✓ Found AllowEventBridgeRuleSendMessage statement"
  echo "$QUEUE_POLICY" | jq '.Statement[] | select(.Sid == "AllowEventBridgeRuleSendMessage") | {
    Sid: .Sid,
    Effect: .Effect,
    Principal: .Principal,
    Action: .Action,
    Condition: .Condition
  }'
  echo ""

  # Check for problematic aws:SourceAccount condition
  if echo "$QUEUE_POLICY" | jq -e '.Statement[] | select(.Sid == "AllowEventBridgeRuleSendMessage") | .Condition.StringEquals."aws:SourceAccount"' >/dev/null 2>&1; then
    echo "  ⚠ WARNING: Found aws:SourceAccount condition"
    echo "  This may block cross-account events from Core account"
    CONDITION_VALUE=$(echo "$QUEUE_POLICY" | jq -r '.Statement[] | select(.Sid == "AllowEventBridgeRuleSendMessage") | .Condition.StringEquals."aws:SourceAccount"')
    echo "  Condition value: $CONDITION_VALUE"
    echo "  Should use: aws:SourceArn instead"
  else
    echo "  ✓ No aws:SourceAccount condition (good)"
  fi

  # Check for aws:SourceArn condition
  if echo "$QUEUE_POLICY" | jq -e '.Statement[] | select(.Sid == "AllowEventBridgeRuleSendMessage") | .Condition.ArnEquals."aws:SourceArn"' >/dev/null 2>&1; then
    echo "  ✓ Using aws:SourceArn condition (correct)"
    SOURCE_ARN=$(echo "$QUEUE_POLICY" | jq -r '.Statement[] | select(.Sid == "AllowEventBridgeRuleSendMessage") | .Condition.ArnEquals."aws:SourceArn"')
    echo "  Source ARN: $SOURCE_ARN"
  else
    echo "  ✗ Missing aws:SourceArn condition"
  fi
else
  echo "✗ MISSING: AllowEventBridgeRuleSendMessage statement"
  echo "  EventBridge cannot send messages to queue"
fi
echo ""

# RPS Lambda Role Policies
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "5. RPS Lambda Role Policies"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Checking if Lambda role has necessary permissions..."
echo ""

LAMBDA_ROLE_ARN=$(aws_rps lambda get-function \
  --function-name "$LAMBDA_NAME" \
  --region "$REGION" \
  --query 'Configuration.Role' \
  --output text)

ROLE_NAME=$(echo "$LAMBDA_ROLE_ARN" | cut -d'/' -f2)
echo "Lambda Role: $ROLE_NAME"
echo ""

POLICIES=$(aws_rps iam list-role-policies \
  --role-name "$ROLE_NAME" \
  --query 'PolicyNames' \
  --output text)

for policy_name in $POLICIES; do
  POLICY_DOC=$(aws_rps iam get-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "$policy_name" \
    --query 'PolicyDocument')

  # Check for S3 read permissions
  if echo "$POLICY_DOC" | jq -e '.Statement[] | select(.Sid == "ReadFromStackCoreBucket")' >/dev/null 2>&1; then
    echo "✓ Found ReadFromStackCoreBucket"

    if echo "$POLICY_DOC" | jq -e '.Statement[] | select(.Sid == "ReadFromStackCoreBucket") | .Resource[]' | grep -q "$BUCKET_NAME"; then
      echo "  ✓ Bucket name matches"
    else
      echo "  ✗ Bucket name mismatch"
    fi
  fi

  # Check for S3 write permissions
  if echo "$POLICY_DOC" | jq -e '.Statement[] | select(.Sid == "WriteToStackCoreBucket")' >/dev/null 2>&1; then
    echo "✓ Found WriteToStackCoreBucket"

    if echo "$POLICY_DOC" | jq -e '.Statement[] | select(.Sid == "WriteToStackCoreBucket") | .Resource[]' | grep -q "$BUCKET_NAME/output"; then
      echo "  ✓ Output prefix matches"
    else
      echo "  ✗ Output prefix mismatch"
    fi
  fi

  # Check for KMS permissions
  if echo "$POLICY_DOC" | jq -e '.Statement[] | select(.Sid == "DecryptStackCoreBucket")' >/dev/null 2>&1; then
    echo "✓ Found DecryptStackCoreBucket"

    if echo "$POLICY_DOC" | jq -e '.Statement[] | select(.Sid == "DecryptStackCoreBucket") | .Condition.StringEquals."kms:ViaService"' | grep -q "s3.${REGION}.amazonaws.com"; then
      echo "  ✓ kms:ViaService condition present"
    else
      echo "  ✗ kms:ViaService condition missing"
    fi
  fi

  # Check for SQS permissions
  if echo "$POLICY_DOC" | jq -e '.Statement[] | select(.Sid == "AccessSQSQueue")' >/dev/null 2>&1; then
    echo "✓ Found AccessSQSQueue"
  fi
done

echo ""

# Summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Policy Verification Summary"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Required cross-account policies:"
echo "  1. Core S3 bucket → Allow RPS Lambda read/write"
echo "  2. Core KMS key → Allow RPS Lambda decrypt/encrypt via S3"
echo "  3. RPS Custom Event Bus → Allow Core account PutEvents"
echo "  4. RPS SQS queue → Allow EventBridge SendMessage (with SourceArn)"
echo "  5. RPS Lambda role → S3, KMS, SQS permissions"
echo ""
echo "If any checks failed above, redeploy the affected stack"
echo ""

echo "=========================================="
echo "Policy Check Complete"
echo "=========================================="
