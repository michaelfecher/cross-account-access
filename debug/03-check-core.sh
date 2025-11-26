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
# CHECK 1: Input Bucket EventBridge Configuration
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CHECK 1: Input Bucket EventBridge Enabled"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Input Bucket: $INPUT_BUCKET_NAME"
echo ""

INPUT_EB_CONFIG=$(aws_core s3api get-bucket-notification-configuration \
  --bucket "$INPUT_BUCKET_NAME" 2>/dev/null | jq -r '.EventBridgeConfiguration // empty')

if [ -n "$INPUT_EB_CONFIG" ]; then
  echo "✅ PASS: Input bucket has EventBridge notifications enabled"
else
  echo "❌ FAIL: Input bucket EventBridge notifications NOT enabled"
  echo ""
  echo "SOLUTION: Redeploy Core Stack"
  echo "  cdk deploy ${STAGE}-StackCore --profile ${CORE_PROFILE:-core-account}"
  FAILED=1
fi

echo ""
echo "Output Bucket: $OUTPUT_BUCKET_NAME"
OUTPUT_EB_CONFIG=$(aws_core s3api get-bucket-notification-configuration \
  --bucket "$OUTPUT_BUCKET_NAME" 2>/dev/null | jq -r '.EventBridgeConfiguration // empty')

if [ -z "$OUTPUT_EB_CONFIG" ]; then
  echo "✅ PASS: Output bucket has NO EventBridge notifications (correct)"
else
  echo "⚠️  WARNING: Output bucket has EventBridge enabled (not needed)"
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
  echo "  cdk deploy ${STAGE}-StackCore --profile ${CORE_PROFILE:-core-account}"
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

# Check if pattern matches S3 Object Created events for input bucket
SOURCE=$(echo "$EVENT_PATTERN" | jq -r '.source[0] // empty')
DETAIL_TYPE=$(echo "$EVENT_PATTERN" | jq -r '."detail-type"[0] // empty')
BUCKET_CHECK=$(echo "$EVENT_PATTERN" | jq -r '.detail.bucket.name[0] // empty')

if [ "$SOURCE" = "aws.s3" ] && [ "$DETAIL_TYPE" = "Object Created" ] && \
   [ "$BUCKET_CHECK" = "$INPUT_BUCKET_NAME" ]; then
  echo "✅ PASS: Event pattern correctly filters S3 Object Created in input bucket"
  echo "  Bucket: $INPUT_BUCKET_NAME"
else
  echo "❌ FAIL: Event pattern incorrect"
  echo "  Source: $SOURCE (expected: aws.s3)"
  echo "  DetailType: $DETAIL_TYPE (expected: Object Created)"
  echo "  Bucket: $BUCKET_CHECK (expected: $INPUT_BUCKET_NAME)"
  echo ""
  echo "SOLUTION: Redeploy Core Stack"
  echo "  cdk deploy ${STAGE}-StackCore --profile ${CORE_PROFILE:-core-account}"
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
  echo "  cdk deploy ${STAGE}-StackCore --profile ${CORE_PROFILE:-core-account}"
  FAILED=1
fi
echo ""

# ============================================
# CHECK 5: S3AccessRole (AssumeRole Pattern)
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CHECK 5: S3AccessRole Exists and Has Correct Trust Policy"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Role: ${STAGE}-s3-access-role"
echo ""

S3_ACCESS_ROLE_ARN=$(aws_core iam get-role \
  --role-name "${STAGE}-s3-access-role" \
  --query 'Role.Arn' \
  --output text 2>/dev/null)

if [ -n "$S3_ACCESS_ROLE_ARN" ] && [ "$S3_ACCESS_ROLE_ARN" != "None" ]; then
  echo "✅ PASS: S3AccessRole exists"
  echo "  ARN: $S3_ACCESS_ROLE_ARN"

  # Check trust policy allows RPS Lambda roles
  TRUST_POLICY=$(aws_core iam get-role \
    --role-name "${STAGE}-s3-access-role" \
    --query 'Role.AssumeRolePolicyDocument' 2>/dev/null)

  TRUST_PRINCIPAL=$(echo "$TRUST_POLICY" | jq -r '.Statement[0].Principal.AWS // empty')
  TRUST_CONDITION=$(echo "$TRUST_POLICY" | jq -r '.Statement[0].Condition.StringLike["aws:PrincipalArn"] // empty')

  if [[ "$TRUST_PRINCIPAL" == *":root" ]] && [[ "$TRUST_CONDITION" == *"processor-lambda-role"* ]]; then
    echo "✅ PASS: Trust policy allows RPS Lambda roles with StringLike condition"
  else
    echo "❌ FAIL: Trust policy incorrect"
    echo "  Principal: $TRUST_PRINCIPAL"
    echo "  Condition: $TRUST_CONDITION"
    FAILED=1
  fi
else
  echo "❌ FAIL: S3AccessRole does not exist"
  echo ""
  echo "SOLUTION: Redeploy Core Stack"
  echo "  cdk deploy ${STAGE}-StackCore --profile ${CORE_PROFILE:-core-account}"
  FAILED=1
fi
echo ""

# ============================================
# CHECK 6: Bucket Policies (Defense in Depth Only)
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CHECK 6: Bucket Policies (Defense in Depth)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Note: With AssumeRole pattern, bucket policies should only deny public access"
echo ""

INPUT_BUCKET_POLICY=$(aws_core s3api get-bucket-policy \
  --bucket "$INPUT_BUCKET_NAME" \
  --query 'Policy' \
  --output text 2>/dev/null)

DENY_STATEMENT=$(echo "$INPUT_BUCKET_POLICY" | jq -r '.Statement[] | select(.Sid == "DenyPublicAccess") // empty')

if [ -n "$DENY_STATEMENT" ]; then
  echo "✅ PASS: Input bucket has DenyPublicAccess policy (correct)"
else
  echo "⚠️  WARNING: Input bucket missing DenyPublicAccess statement"
fi

OUTPUT_BUCKET_POLICY=$(aws_core s3api get-bucket-policy \
  --bucket "$OUTPUT_BUCKET_NAME" \
  --query 'Policy' \
  --output text 2>/dev/null)

DENY_STATEMENT_OUT=$(echo "$OUTPUT_BUCKET_POLICY" | jq -r '.Statement[] | select(.Sid == "DenyPublicAccess") // empty')

if [ -n "$DENY_STATEMENT_OUT" ]; then
  echo "✅ PASS: Output bucket has DenyPublicAccess policy (correct)"
else
  echo "⚠️  WARNING: Output bucket missing DenyPublicAccess statement"
fi
echo ""

# ============================================
# CHECK 8: Cross-Account EventBridge IAM Role
# ============================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CHECK 8: Cross-Account EventBridge IAM Role"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ROLE_NAME="${STAGE}-cross-account-eventbridge-role"
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
  echo "  cdk deploy ${STAGE}-StackCore --profile ${CORE_PROFILE:-core-account}"
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
