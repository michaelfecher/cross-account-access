#!/bin/bash
# Quick Test Commands
# This is a reference file - copy commands manually, don't execute as a script

# Configuration
export PREFIX=dev
export CORE_ACCOUNT_ID=111111111111
export RPS_ACCOUNT_ID=222222222222
export REGION=eu-west-1
export INPUT_BUCKET_NAME=${PREFIX}-core-input-bucket-${CORE_ACCOUNT_ID}-${REGION}
export OUTPUT_BUCKET_NAME=${PREFIX}-core-output-bucket-${CORE_ACCOUNT_ID}-${REGION}

# 1. Upload test file
aws s3 cp test-data/sample-input.txt \
  s3://${INPUT_BUCKET_NAME}/test-$(date +%s).txt \
  --profile core-account

# 2. Wait for processing (30 seconds)
sleep 30

# 3. Check output file was created
aws s3 ls s3://${OUTPUT_BUCKET_NAME}/ --profile core-account

# 4. View latest output file
LATEST=$(aws s3 ls s3://${OUTPUT_BUCKET_NAME}/ --profile core-account | tail -1 | awk '{print $4}')
aws s3 cp s3://${OUTPUT_BUCKET_NAME}/${LATEST} - --profile core-account

# 5. Check Lambda logs
aws logs tail /aws/lambda/${PREFIX}-s3-processor --follow --profile rps-account

# 6. Check for errors in DLQ (should be empty)
aws sqs get-queue-attributes \
  --queue-url https://sqs.${REGION}.amazonaws.com/${RPS_ACCOUNT_ID}/${PREFIX}-processor-dlq \
  --attribute-names ApproximateNumberOfMessages \
  --profile rps-account
