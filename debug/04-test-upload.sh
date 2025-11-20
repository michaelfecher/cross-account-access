#!/usr/bin/env bash
#
# Upload a test file and monitor the event flow
#
# Prerequisites: Source 00-config.sh first
#
# Usage:
#   source debug/00-config.sh
#   bash debug/04-test-upload.sh [filename]

set -e

if [ -z "$PREFIX" ]; then
  echo "Error: Configuration not loaded. Run: source debug/00-config.sh"
  exit 1
fi

# Use provided filename or generate one
FILENAME="${1:-test-$(date +%s).txt}"
INPUT_KEY="input/$FILENAME"
OUTPUT_KEY="output/$FILENAME"

echo "=========================================="
echo "Test Upload and Flow Monitoring"
echo "=========================================="
echo ""
echo "Test file: $FILENAME"
echo "Input path: s3://$BUCKET_NAME/$INPUT_KEY"
echo "Output path: s3://$BUCKET_NAME/$OUTPUT_KEY"
echo ""

# Create test content
TEST_CONTENT="Test upload at $(date -u +%Y-%m-%dT%H:%M:%SZ)
This is a test file to verify cross-account event flow.
File: $FILENAME
Bucket: $BUCKET_NAME
"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 1: Upload test file to input/"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "$TEST_CONTENT" | aws_core s3 cp - "s3://$BUCKET_NAME/$INPUT_KEY"
echo "✓ File uploaded successfully"
echo ""

# Wait for processing
echo "Waiting 10 seconds for event processing..."
sleep 10
echo ""

# Check if output file exists
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 2: Check if output file was created"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if aws_core s3 ls "s3://$BUCKET_NAME/$OUTPUT_KEY" >/dev/null 2>&1; then
  echo "✓ Output file EXISTS!"
  echo ""
  echo "Output file content:"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  aws_core s3 cp "s3://$BUCKET_NAME/$OUTPUT_KEY" -
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "✅ SUCCESS: End-to-end flow working correctly!"
else
  echo "✗ Output file NOT FOUND"
  echo ""
  echo "Troubleshooting: Running flow trace to identify issue..."
  echo ""

  # Run flow tracing
  bash "$(dirname "$0")/01-trace-flow.sh"

  echo ""
  echo "Additional checks:"
  echo ""

  # Check SQS for messages
  echo "Checking SQS queue for stuck messages..."
  QUEUE_URL=$(aws_rps sqs get-queue-url \
    --queue-name "$QUEUE_NAME" \
    --region "$REGION" \
    --query 'QueueUrl' \
    --output text)

  MESSAGES=$(aws_rps sqs get-queue-attributes \
    --queue-url "$QUEUE_URL" \
    --attribute-names ApproximateNumberOfMessages \
    --region "$REGION" \
    --query 'Attributes.ApproximateNumberOfMessages' \
    --output text)

  echo "Messages in queue: $MESSAGES"

  if [ "$MESSAGES" != "0" ]; then
    echo ""
    echo "Messages are stuck in queue. Checking Lambda logs..."
    echo ""
    aws_rps logs tail "/aws/lambda/$LAMBDA_NAME" \
      --since 2m \
      --region "$REGION" || true
  fi

  echo ""
  echo "❌ FAILED: Output file was not created"
  echo ""
  echo "Next steps:"
  echo "  1. Review flow trace above to identify which step failed"
  echo "  2. Check Lambda logs: aws logs tail /aws/lambda/$LAMBDA_NAME --follow"
  echo "  3. Run detailed checks:"
  echo "     - bash debug/02-check-core.sh"
  echo "     - bash debug/03-check-rps.sh"
  echo "     - bash debug/05-check-policies.sh"
fi

echo ""
echo "=========================================="
echo "Test Complete"
echo "=========================================="
