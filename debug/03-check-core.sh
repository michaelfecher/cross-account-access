#!/usr/bin/env bash
#
# Check Core Account resources and configuration
#
# Usage:
#   bash debug/03-check-core.sh

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the configuration
source "$SCRIPT_DIR/00-config.sh"

echo "=========================================="
echo "Core Account Resources Check"
echo "=========================================="
echo ""

# Track overall status
FAILED=0

# ============================================
# CHECK 1: S3 Bucket EventBridge Configuration
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CHECK 1: S3 Bucket EventBridge Enabled"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Bucket: $BUCKET_NAME"
echo ""

EB_CONFIG=$(aws_core s3api get-bucket-notification-configuration \
  --bucket "$BUCKET_NAME" 2>/dev/null | jq -r '.EventBridgeConfiguration // empty')

if [ -n "$EB_CONFIG" ]; then
  echo "✅ PASS: EventBridge notifications enabled"
else
  echo "❌ FAIL: EventBridge notifications NOT enabled"
  echo ""
  echo "SOLUTION: Redeploy Core Stack"
  echo "  cdk deploy ${CDK_DEPLOYMENT_PREFIX}-StackCore --profile ${CORE_PROFILE:-core-account}"
  FAILED=1
fi
echo ""

# ============================================
# CHECK 2: EventBridge Rule Exists and Enabled
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CHECK 2: EventBridge Rule State"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Rule: $CORE_EVENTBRIDGE_RULE"
echo ""

RULE_STATE=$(aws_core events describe-rule \
  --name "$CORE_EVENTBRIDGE_RULE" \
  --region "$REGION" 2>/dev/null | jq -r '.State // empty')

if [ "$RULE_STATE" = "ENABLED" ]; then
  echo "✅ PASS: Rule is ENABLED"
else
  echo "❌ FAIL: Rule state is '$RULE_STATE' (expected ENABLED)"
  echo ""
  echo "SOLUTION: Check if rule exists and redeploy if needed"
  echo "  cdk deploy ${CDK_DEPLOYMENT_PREFIX}-StackCore --profile ${CORE_PROFILE:-core-account}"
  FAILED=1
fi
echo ""

# ============================================
# CHECK 3: EventBridge Rule Event Pattern
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CHECK 3: EventBridge Rule Event Pattern"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

EVENT_PATTERN=$(aws_core events describe-rule \
  --name "$CORE_EVENTBRIDGE_RULE" \
  --region "$REGION" 2>/dev/null | jq -r '.EventPattern // empty')

# Check if pattern matches S3 Object Created events with configured input prefix
SOURCE=$(echo "$EVENT_PATTERN" | jq -r '.source[0] // empty')
DETAIL_TYPE=$(echo "$EVENT_PATTERN" | jq -r '."detail-type"[0] // empty')
BUCKET_CHECK=$(echo "$EVENT_PATTERN" | jq -r '.detail.bucket.name[0] // empty')
PREFIX_CHECK=$(echo "$EVENT_PATTERN" | jq -r '.detail.object.key[0].prefix // empty')

if [ "$SOURCE" = "aws.s3" ] && [ "$DETAIL_TYPE" = "Object Created" ] && \
   [ "$BUCKET_CHECK" = "$BUCKET_NAME" ] && [ "$PREFIX_CHECK" = "$INPUT_PREFIX" ]; then
  echo "✅ PASS: Event pattern correctly filters S3 Object Created in $BUCKET_NAME/${INPUT_PREFIX}"
else
  echo "❌ FAIL: Event pattern incorrect"
  echo "  Source: $SOURCE (expected: aws.s3)"
  echo "  DetailType: $DETAIL_TYPE (expected: Object Created)"
  echo "  Bucket: $BUCKET_CHECK (expected: $BUCKET_NAME)"
  echo "  Prefix: $PREFIX_CHECK (expected: $INPUT_PREFIX)"
  echo ""
  echo "SOLUTION: Redeploy Core Stack"
  echo "  cdk deploy ${CDK_DEPLOYMENT_PREFIX}-StackCore --profile ${CORE_PROFILE:-core-account}"
  FAILED=1
fi
echo ""

# ============================================
# CHECK 4: EventBridge Rule Target
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CHECK 4: EventBridge Rule Target"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

EXPECTED_TARGET="arn:aws:events:${REGION}:${RPS_ACCOUNT_ID}:event-bus/${CUSTOM_EVENT_BUS}"
ACTUAL_TARGET=$(aws_core events list-targets-by-rule \
  --rule "$CORE_EVENTBRIDGE_RULE" \
  --region "$REGION" 2>/dev/null | jq -r '.Targets[0].Arn // empty')

ROLE_ARN=$(aws_core events list-targets-by-rule \
  --rule "$CORE_EVENTBRIDGE_RULE" \
  --region "$REGION" 2>/dev/null | jq -r '.Targets[0].RoleArn // empty')

if [ "$ACTUAL_TARGET" = "$EXPECTED_TARGET" ]; then
  echo "✅ PASS: Target is RPS custom event bus"
  echo "  Target: $ACTUAL_TARGET"
  echo "  Role: $ROLE_ARN"
else
  echo "❌ FAIL: Target ARN mismatch"
  echo "  Expected: $EXPECTED_TARGET"
  echo "  Actual:   $ACTUAL_TARGET"
  echo ""
  echo "SOLUTION: Redeploy Core Stack with correct RPS account ID"
  echo "  cdk deploy ${CDK_DEPLOYMENT_PREFIX}-StackCore --profile ${CORE_PROFILE:-core-account}"
  FAILED=1
fi
echo ""

# ============================================
# CHECK 5: S3 Bucket Policy - Lambda Read
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CHECK 5: S3 Bucket Policy - Lambda Read Access"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

BUCKET_POLICY=$(aws_core s3api get-bucket-policy \
  --bucket "$BUCKET_NAME" \
  --query 'Policy' \
  --output text 2>/dev/null)

READ_STATEMENT=$(echo "$BUCKET_POLICY" | jq -r '.Statement[] | select(.Sid == "AllowAccountRpsLambdaRead") // empty')

if [ -n "$READ_STATEMENT" ]; then
  # Verify it allows GetObject and ListBucket
  ACTIONS=$(echo "$READ_STATEMENT" | jq -r '.Action | if type == "array" then .[] else . end' | sort | tr '\n' ' ')
  EXPECTED_ROLE="arn:aws:iam::${RPS_ACCOUNT_ID}:role/${CDK_DEPLOYMENT_PREFIX}-processor-lambda-role"
  ACTUAL_PRINCIPAL=$(echo "$READ_STATEMENT" | jq -r '.Principal.AWS // empty')

  if echo "$ACTIONS" | grep -q "s3:GetObject" && echo "$ACTIONS" | grep -q "s3:ListBucket" && \
     [ "$ACTUAL_PRINCIPAL" = "$EXPECTED_ROLE" ]; then
    echo "✅ PASS: RPS Lambda can read from ${INPUT_PREFIX}*"
    echo "  Principal: $ACTUAL_PRINCIPAL"
  else
    echo "❌ FAIL: Read statement exists but incorrect"
    echo "  Actions: $ACTIONS"
    echo "  Principal: $ACTUAL_PRINCIPAL"
    echo "  Expected: $EXPECTED_ROLE"
    FAILED=1
  fi
else
  echo "❌ FAIL: Missing 'AllowAccountRpsLambdaRead' statement"
  echo ""
  echo "SOLUTION: Redeploy Core Stack"
  echo "  cdk deploy ${CDK_DEPLOYMENT_PREFIX}-StackCore --profile ${CORE_PROFILE:-core-account}"
  FAILED=1
fi
echo ""

# ============================================
# CHECK 6: S3 Bucket Policy - Lambda Write
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CHECK 6: S3 Bucket Policy - Lambda Write Access"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

WRITE_STATEMENT=$(echo "$BUCKET_POLICY" | jq -r '.Statement[] | select(.Sid == "AllowAccountRpsLambdaWrite") // empty')

if [ -n "$WRITE_STATEMENT" ]; then
  ACTIONS=$(echo "$WRITE_STATEMENT" | jq -r '.Action | if type == "array" then .[] else . end' | sort | tr '\n' ' ')
  EXPECTED_ROLE="arn:aws:iam::${RPS_ACCOUNT_ID}:role/${CDK_DEPLOYMENT_PREFIX}-processor-lambda-role"
  ACTUAL_PRINCIPAL=$(echo "$WRITE_STATEMENT" | jq -r '.Principal.AWS // empty')

  if echo "$ACTIONS" | grep -q "s3:PutObject" && [ "$ACTUAL_PRINCIPAL" = "$EXPECTED_ROLE" ]; then
    echo "✅ PASS: RPS Lambda can write to ${OUTPUT_PREFIX}*"
    echo "  Principal: $ACTUAL_PRINCIPAL"
  else
    echo "❌ FAIL: Write statement exists but incorrect"
    echo "  Actions: $ACTIONS"
    echo "  Principal: $ACTUAL_PRINCIPAL"
    echo "  Expected: $EXPECTED_ROLE"
    FAILED=1
  fi
else
  echo "❌ FAIL: Missing 'AllowAccountRpsLambdaWrite' statement"
  echo ""
  echo "SOLUTION: Redeploy Core Stack"
  echo "  cdk deploy ${CDK_DEPLOYMENT_PREFIX}-StackCore --profile ${CORE_PROFILE:-core-account}"
  FAILED=1
fi
echo ""

# ============================================
# CHECK 7: KMS Key Policy
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CHECK 7: KMS Key Policy - Cross-Account Access"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

KEY_ID=$(aws_core s3api get-bucket-encryption \
  --bucket "$BUCKET_NAME" \
  --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.KMSMasterKeyID' \
  --output text 2>/dev/null)

if [ "$KEY_ID" != "None" ] && [ -n "$KEY_ID" ]; then
  echo "KMS Key: $KEY_ID"

  KMS_POLICY=$(aws_core kms get-key-policy \
    --key-id "$KEY_ID" \
    --policy-name default \
    --query 'Policy' \
    --output text 2>/dev/null)

  KMS_STATEMENT=$(echo "$KMS_POLICY" | jq -r '.Statement[] | select(.Sid == "AllowAccountRpsLambdaDecrypt") // empty')

  if [ -n "$KMS_STATEMENT" ]; then
    PRINCIPAL=$(echo "$KMS_STATEMENT" | jq -r '.Principal.AWS // empty')
    CONDITION=$(echo "$KMS_STATEMENT" | jq -r '.Condition.StringEquals["kms:ViaService"] // empty')
    EXPECTED_PRINCIPAL="arn:aws:iam::${RPS_ACCOUNT_ID}:role/${CDK_DEPLOYMENT_PREFIX}-processor-lambda-role"

    if [ "$PRINCIPAL" = "$EXPECTED_PRINCIPAL" ] && [ "$CONDITION" = "s3.${REGION}.amazonaws.com" ]; then
      echo "✅ PASS: RPS Lambda role can decrypt via S3 service"
      echo "  Principal: $PRINCIPAL"
    else
      echo "❌ FAIL: KMS policy incorrect"
      echo "  Expected Principal: $EXPECTED_PRINCIPAL"
      echo "  Actual Principal:   $PRINCIPAL"
      echo "  Condition: $CONDITION (expected: s3.${REGION}.amazonaws.com)"
      FAILED=1
    fi
  else
    echo "❌ FAIL: Missing 'AllowAccountRpsLambdaDecrypt' statement"
    echo ""
    echo "SOLUTION: Redeploy Core Stack"
    echo "  cdk deploy ${CDK_DEPLOYMENT_PREFIX}-StackCore --profile ${CORE_PROFILE:-core-account}"
    FAILED=1
  fi
else
  echo "⚠️  SKIP: No KMS encryption (using S3 default encryption)"
fi
echo ""

# ============================================
# CHECK 8: Cross-Account EventBridge IAM Role
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CHECK 8: Cross-Account EventBridge IAM Role"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ROLE_NAME="${CDK_DEPLOYMENT_PREFIX}-cross-account-eventbridge-role"
echo "Role: $ROLE_NAME"
echo ""

# Check role exists
ROLE_ARN=$(aws_core iam get-role \
  --role-name "$ROLE_NAME" \
  --query 'Role.Arn' \
  --output text 2>/dev/null)

if [ -n "$ROLE_ARN" ] && [ "$ROLE_ARN" != "None" ]; then
  echo "✅ PASS: IAM role exists"
  echo "  ARN: $ROLE_ARN"

  # Check trust policy
  TRUST_POLICY=$(aws_core iam get-role \
    --role-name "$ROLE_NAME" \
    --query 'Role.AssumeRolePolicyDocument' 2>/dev/null)

  TRUSTED_SERVICE=$(echo "$TRUST_POLICY" | jq -r '.Statement[0].Principal.Service // empty')

  if [ "$TRUSTED_SERVICE" = "events.amazonaws.com" ]; then
    echo "✅ PASS: Role trusts events.amazonaws.com"
  else
    echo "❌ FAIL: Trust policy incorrect"
    echo "  Expected: events.amazonaws.com"
    echo "  Actual: $TRUSTED_SERVICE"
    FAILED=1
  fi

  # Check inline policy
  POLICY_NAME=$(aws_core iam list-role-policies \
    --role-name "$ROLE_NAME" \
    --query 'PolicyNames[0]' \
    --output text 2>/dev/null)

  if [ -n "$POLICY_NAME" ] && [ "$POLICY_NAME" != "None" ]; then
    POLICY_DOC=$(aws_core iam get-role-policy \
      --role-name "$ROLE_NAME" \
      --policy-name "$POLICY_NAME" \
      --query 'PolicyDocument' 2>/dev/null)

    TARGET_BUS="arn:aws:events:${REGION}:${RPS_ACCOUNT_ID}:event-bus/${CUSTOM_EVENT_BUS}"
    POLICY_RESOURCE=$(echo "$POLICY_DOC" | jq -r '.Statement[0].Resource // empty')
    POLICY_ACTION=$(echo "$POLICY_DOC" | jq -r '.Statement[0].Action // empty')

    if [ "$POLICY_RESOURCE" = "$TARGET_BUS" ] && [ "$POLICY_ACTION" = "events:PutEvents" ]; then
      echo "✅ PASS: Role can PutEvents to RPS custom bus"
      echo "  Resource: $POLICY_RESOURCE"
    else
      echo "❌ FAIL: Policy incorrect"
      echo "  Expected Resource: $TARGET_BUS"
      echo "  Actual Resource: $POLICY_RESOURCE"
      echo "  Action: $POLICY_ACTION"
      FAILED=1
    fi
  else
    echo "❌ FAIL: No inline policy found"
    FAILED=1
  fi
else
  echo "❌ FAIL: IAM role does not exist"
  echo ""
  echo "SOLUTION: Redeploy Core Stack"
  echo "  cdk deploy ${CDK_DEPLOYMENT_PREFIX}-StackCore --profile ${CORE_PROFILE:-core-account}"
  FAILED=1
fi
echo ""

# ============================================
# Summary
# ============================================
echo "=========================================="
if [ $FAILED -eq 0 ]; then
  echo "✅ ALL CHECKS PASSED"
  echo "Core Account is properly configured"
else
  echo "❌ SOME CHECKS FAILED"
  echo "Review errors above and redeploy as needed"
  echo "=========================================="
  exit 1
fi
echo "=========================================="
