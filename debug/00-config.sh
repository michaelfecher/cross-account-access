#!/usr/bin/env bash
#
# Configuration script for debugging cross-account event flow
# Source this file before running other debug scripts
#
# Compatible with both bash and zsh
#
# Usage:
#   # Option 1: Using AWS SSO profiles
#   export CORE_PROFILE=core-account
#   export RPS_PROFILE=rps-account
#   source debug/00-config.sh
#
#   # Option 2: Using environment variables (AWS_ACCESS_KEY_ID, etc.)
#   # Set credentials for Core account
#   export AWS_ACCESS_KEY_ID=...
#   export AWS_SECRET_ACCESS_KEY=...
#   export AWS_SESSION_TOKEN=...  # if using temporary credentials
#   # Run Core account checks, then switch to RPS credentials
#

# === Required Configuration ===
export STAGE="${STAGE:-dev}"
export REGION="${REGION:-eu-west-1}"
export CORE_ACCOUNT_ID="${CORE_ACCOUNT_ID:-111111111111}"
export RPS_ACCOUNT_ID="${RPS_ACCOUNT_ID:-222222222222}"

# === Developer Prefix (optional for multi-developer isolation) ===
# If set, creates separate stack resources for this developer
# Example: CDK_DEPLOYMENT_PREFIX=john → dev-john-processor-queue
export CDK_DEPLOYMENT_PREFIX="${CDK_DEPLOYMENT_PREFIX:-}"

# === Derived Resource Names ===
# Resource naming includes developer prefix for isolation
if [ -n "$CDK_DEPLOYMENT_PREFIX" ]; then
  RESOURCE_PREFIX="${STAGE}-${CDK_DEPLOYMENT_PREFIX}"
else
  RESOURCE_PREFIX="${STAGE}"
fi

export INPUT_BUCKET_NAME="${STAGE}-core-input-bucket-${CORE_ACCOUNT_ID}-${REGION}"
export OUTPUT_BUCKET_NAME="${STAGE}-core-output-bucket-${CORE_ACCOUNT_ID}-${REGION}"
export QUEUE_NAME="${RESOURCE_PREFIX}-processor-queue"
export LAMBDA_NAME="${RESOURCE_PREFIX}-s3-processor"
export CORE_EVENTBRIDGE_RULE="${STAGE}-s3-input-events"
export RPS_EVENTBRIDGE_RULE="${RESOURCE_PREFIX}-receive-s3-events"
export CUSTOM_EVENT_BUS="${STAGE}-cross-account-bus"

# === Profile-based vs Environment-based Authentication ===
# If CORE_PROFILE is set, use --profile flag, otherwise use environment variables
if [ -n "$CORE_PROFILE" ]; then
  export CORE_AUTH="--profile $CORE_PROFILE"
else
  export CORE_AUTH=""
fi

if [ -n "$RPS_PROFILE" ]; then
  export RPS_AUTH="--profile $RPS_PROFILE"
else
  export RPS_AUTH=""
fi

# === Helper Functions ===
aws_core() {
  if [ -n "$CORE_PROFILE" ]; then
    aws --profile "$CORE_PROFILE" "$@"
  else
    aws "$@"
  fi
}

aws_rps() {
  if [ -n "$RPS_PROFILE" ]; then
    aws --profile "$RPS_PROFILE" "$@"
  else
    aws "$@"
  fi
}

# Note: Functions are available in current shell after sourcing
# No need to export in zsh/bash when sourcing

# === Display Configuration ===
echo "=== Debug Configuration ==="
echo "STAGE:              $STAGE"
echo "REGION:             $REGION"
echo "CORE_ACCOUNT_ID:    $CORE_ACCOUNT_ID"
echo "RPS_ACCOUNT_ID:     $RPS_ACCOUNT_ID"
echo ""
echo "INPUT_BUCKET_NAME:  $INPUT_BUCKET_NAME"
echo "OUTPUT_BUCKET_NAME: $OUTPUT_BUCKET_NAME"
echo "QUEUE_NAME:         $QUEUE_NAME"
echo "LAMBDA_NAME:        $LAMBDA_NAME"
echo "CUSTOM_EVENT_BUS:   $CUSTOM_EVENT_BUS"
echo ""
if [ -n "$CORE_PROFILE" ]; then
  echo "Core Auth:         Profile ($CORE_PROFILE)"
else
  echo "Core Auth:         Environment variables"
fi
if [ -n "$RPS_PROFILE" ]; then
  echo "RPS Auth:          Profile ($RPS_PROFILE)"
else
  echo "RPS Auth:          Environment variables"
fi
echo "===================="
echo ""
