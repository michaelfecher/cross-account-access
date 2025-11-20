#!/usr/bin/env bash
#
# Check Core Account resources and configuration
#
# Prerequisites: Source 00-config.sh first
#
# Usage:
#   source debug/00-config.sh
#   bash debug/02-check-core.sh

set -e

if [ -z "$PREFIX" ]; then
  echo "Error: Configuration not loaded. Run: source debug/00-config.sh"
  exit 1
fi

echo "=========================================="
echo "Core Account Resources Check"
echo "=========================================="
echo ""

# S3 Bucket EventBridge Configuration
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "1. S3 Bucket EventBridge Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Bucket: $BUCKET_NAME"
echo ""
aws_core s3api get-bucket-notification-configuration \
  --bucket "$BUCKET_NAME" | jq '.'
echo ""
echo "Expected: EventBridgeConfiguration: {}"
echo "If empty: Redeploy Core Stack with eventBridgeEnabled: true"
echo ""

# EventBridge Rule
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "2. EventBridge Rule Configuration"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Rule: $CORE_EVENTBRIDGE_RULE"
echo ""
echo "2a. Rule details:"
aws_core events describe-rule \
  --name "$CORE_EVENTBRIDGE_RULE" \
  --region "$REGION" | jq '{
  Name: .Name,
  State: .State,
  EventPattern: .EventPattern | fromjson
}'

echo ""
echo "2b. Rule targets:"
aws_core events list-targets-by-rule \
  --rule "$CORE_EVENTBRIDGE_RULE" \
  --region "$REGION" | jq '.Targets[] | {
  Id: .Id,
  Arn: .Arn,
  RoleArn: .RoleArn
}'

echo ""
echo "Expected target ARN: arn:aws:events:${REGION}:${RPS_ACCOUNT_ID}:event-bus/${CUSTOM_EVENT_BUS}"
echo "If different: Redeploy Core Stack"
echo ""

# S3 Bucket Policy
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "3. S3 Bucket Policy (Cross-Account Access)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
aws_core s3api get-bucket-policy \
  --bucket "$BUCKET_NAME" \
  --query 'Policy' \
  --output text | jq '.Statement[] | {
  Sid: .Sid,
  Effect: .Effect,
  Principal: .Principal,
  Action: .Action,
  Resource: .Resource,
  Condition: .Condition
}'

echo ""
echo "Expected statements:"
echo "  - AllowAccountRpsLambdaRead: RPS Lambda can GetObject from input/*"
echo "  - AllowAccountRpsLambdaWrite: RPS Lambda can PutObject to output/*"
echo ""

# KMS Key Policy
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "4. KMS Key Policy (Cross-Account Access)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Get KMS key ID from bucket encryption
KEY_ID=$(aws_core s3api get-bucket-encryption \
  --bucket "$BUCKET_NAME" \
  --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.KMSMasterKeyID' \
  --output text)

echo "KMS Key: $KEY_ID"
echo ""

if [ "$KEY_ID" != "None" ] && [ -n "$KEY_ID" ]; then
  aws_core kms get-key-policy \
    --key-id "$KEY_ID" \
    --policy-name default \
    --query 'Policy' \
    --output text | jq '.Statement[] | select(.Sid == "AllowAccountRpsLambdaDecrypt") | {
    Sid: .Sid,
    Effect: .Effect,
    Principal: .Principal,
    Action: .Action,
    Condition: .Condition
  }'
  echo ""
  echo "Expected: RPS account principal with kms:ViaService condition for S3"
else
  echo "No KMS key found (using default encryption)"
fi
echo ""

# Cross-Account EventBridge IAM Role
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "5. Cross-Account EventBridge IAM Role"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
ROLE_NAME="${PREFIX}-cross-account-eventbridge-role"
echo "Role: $ROLE_NAME"
echo ""

echo "5a. Trust policy (assume role):"
aws_core iam get-role \
  --role-name "$ROLE_NAME" \
  --query 'Role.AssumeRolePolicyDocument' | jq '.'

echo ""
echo "5b. Inline policies:"
aws_core iam list-role-policies \
  --role-name "$ROLE_NAME" \
  --query 'PolicyNames'

echo ""
POLICY_NAME=$(aws_core iam list-role-policies \
  --role-name "$ROLE_NAME" \
  --query 'PolicyNames[0]' \
  --output text)

if [ -n "$POLICY_NAME" ]; then
  aws_core iam get-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name "$POLICY_NAME" \
    --query 'PolicyDocument' | jq '.Statement[] | {
    Effect: .Effect,
    Action: .Action,
    Resource: .Resource
  }'
fi

echo ""
echo "Expected: events:PutEvents to arn:aws:events:${REGION}:${RPS_ACCOUNT_ID}:event-bus/${CUSTOM_EVENT_BUS}"
echo ""

echo "=========================================="
echo "Core Account Check Complete"
echo "=========================================="
