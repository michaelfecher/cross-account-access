#!/bin/bash
# Developer Deployment Helper Script
# Usage: ./scripts/dev-deploy.sh [your-prefix]

set -e

# Get prefix from argument or prompt
if [ -z "$1" ]; then
  read -p "Enter your developer prefix (e.g., your name): " PREFIX
else
  PREFIX="$1"
fi

# Load config from .env if it exists
if [ -f ".env" ]; then
  echo "Loading configuration from .env..."
  source .env
fi

# Set defaults
export PREFIX="${PREFIX}"
export ACCOUNT_CORE_ID="${ACCOUNT_CORE_ID:-111111111111}"
export ACCOUNT_RPS_ID="${ACCOUNT_RPS_ID:-222222222222}"
export REGION="${REGION:-eu-west-1}"

echo "========================================="
echo "Developer Deployment"
echo "========================================="
echo "Prefix:           ${PREFIX}"
echo "Core Account:     ${ACCOUNT_CORE_ID}"
echo "RPS Account:      ${ACCOUNT_RPS_ID}"
echo "Region:           ${REGION}"
echo "========================================="
echo ""

# Confirm
read -p "Deploy RPS stack with these settings? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Deployment cancelled."
  exit 1
fi

# Build
echo "Building..."
npm run build

# Synth
echo "Synthesizing CDK..."
npx cdk synth ${PREFIX}-StackRps

# Diff (optional)
read -p "Show diff before deploying? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
  npx cdk diff ${PREFIX}-StackRps --profile rps-account || true
fi

# Deploy
echo ""
echo "Deploying ${PREFIX}-StackRps..."
npx cdk deploy ${PREFIX}-StackRps --profile rps-account

echo ""
echo "========================================="
echo "Deployment Complete!"
echo "========================================="
echo ""
echo "Your resources:"
echo "  Lambda:        ${PREFIX}-s3-processor"
echo "  SQS Queue:     ${PREFIX}-processor-queue"
echo "  IAM Role:      ${PREFIX}-processor-lambda-role"
echo "  Stack:         ${PREFIX}-rps-stack"
echo ""
echo "Core team resources (must be deployed by Core team):"
echo "  Input Bucket:  ${PREFIX}-core-input-bucket-${ACCOUNT_CORE_ID}-${REGION}"
echo "  Output Bucket: ${PREFIX}-core-output-bucket-${ACCOUNT_CORE_ID}-${REGION}"
echo "  Stack:         ${PREFIX}-core-stack"
echo ""
echo "Next steps:"
echo "  1. Coordinate with Core team to deploy ${PREFIX}-StackCore"
echo "  2. Test: aws s3 cp test-data/sample-input.txt s3://${PREFIX}-core-input-bucket-${ACCOUNT_CORE_ID}-${REGION}/test.txt --profile core-account"
echo "  3. View logs: aws logs tail /aws/lambda/${PREFIX}-s3-processor --follow --profile rps-account"
echo ""
