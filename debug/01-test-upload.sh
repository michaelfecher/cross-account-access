#!/usr/bin/env bash
#
# Upload a test file and monitor the event flow
# START HERE - This is the first script to run for debugging
#
# Usage:
#   bash debug/01-test-upload.sh [filename]

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the configuration
source "$SCRIPT_DIR/00-config.sh"

# Use provided filename or generate one
FILENAME="${1:-test-$(date +%s).txt}"
INPUT_KEY="${INPUT_PREFIX}${FILENAME}"
OUTPUT_KEY="${OUTPUT_PREFIX}${FILENAME}"

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
echo "Step 1: Upload test file to ${INPUT_PREFIX}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "$TEST_CONTENT" | aws_core s3 cp - "s3://$BUCKET_NAME/$INPUT_KEY"
echo "✓ File uploaded successfully"
echo ""

# Wait for processing (typically takes 20-30 seconds)
echo "Waiting 30 seconds for event processing..."
echo "(Cross-account flow: S3 → EventBridge → SQS → Lambda)"
sleep 30
echo ""

# Check if output file exists (SOURCE OF TRUTH - not CloudWatch metrics!)
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Step 2: Check if output file was created"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "(This is the definitive test - if file exists, system works!)"
echo ""

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
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Troubleshooting Steps (in order):"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "1. Check SQS queue for stuck messages"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
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
    --output text 2>/dev/null)

  echo "Messages in queue: ${MESSAGES:-0}"
  echo ""

  if [ "${MESSAGES:-0}" != "0" ]; then
    echo "→ Messages stuck in queue! Checking Lambda logs for errors..."
    echo ""
    aws_rps logs tail "/aws/lambda/$LAMBDA_NAME" \
      --since 5m \
      --region "$REGION" 2>/dev/null || echo "Could not fetch Lambda logs"
  else
    echo "→ Queue is empty"
  fi

  echo ""
  echo "2. Check Lambda recent executions"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  aws_rps logs tail "/aws/lambda/$LAMBDA_NAME" \
    --since 2m \
    --region "$REGION" 2>/dev/null || echo "No recent Lambda logs found"

  echo ""
  echo "3. Verify configuration (immediate checks)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Run these scripts to check configuration:"
  echo "  • bash debug/03-check-core.sh   - Core account setup"
  echo "  • bash debug/04-check-rps.sh    - RPS account setup"
  echo ""

  echo ""
  echo "4. Check CloudWatch metrics (LAST - metrics delayed 5-15 min)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
  echo "Run this ONLY if above steps don't identify the issue:"
  echo "  • bash debug/02-trace-flow.sh   - Event flow metrics"
  echo ""

  echo ""
  echo "❌ FAILED: Output file was not created"
  echo ""
  echo "Next steps:"
  echo "  1. Check if messages are stuck in SQS (see above)"
  echo "  2. Check Lambda logs for errors (see above)"
  echo "  3. Verify configuration with check scripts (03 and 04)"
  echo "  4. Last resort: Check CloudWatch metrics (02-trace-flow.sh)"
fi

echo ""
echo "=========================================="
echo "Test Complete"
echo "=========================================="
