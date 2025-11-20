/**
 * Integration Test: EventBridge Cross-Account Event Transfer
 *
 * Purpose: Tests the connectivity and message transfer from Core Account's EventBridge
 * to RPS Account's EventBridge.
 *
 * Prerequisites:
 * - Both Core Stack and RPS Stack must be deployed
 * - AWS credentials must be configured for both accounts
 * - Set environment variables: ACCOUNT_CORE_ID, ACCOUNT_RPS_ID, PREFIX
 *
 * Test Flow:
 * 1. Put a test event directly to Core Account's EventBridge
 * 2. Wait for the event to propagate to RPS Account
 * 3. Verify the event appears in RPS Account's SQS queue
 */

import {
  EventBridgeClient,
  PutEventsCommand,
} from '@aws-sdk/client-eventbridge';
import {
  SQSClient,
  ReceiveMessageCommand,
  DeleteMessageCommand,
  PurgeQueueCommand,
  GetQueueAttributesCommand,
} from '@aws-sdk/client-sqs';

const PREFIX = process.env.PREFIX || 'dev';
const ACCOUNT_CORE_ID = process.env.ACCOUNT_CORE_ID || '111111111111';
const ACCOUNT_RPS_ID = process.env.ACCOUNT_RPS_ID || '222222222222';
const REGION = 'eu-central-1';
const QUEUE_NAME = `${PREFIX}-processor-queue`;

describe('EventBridge Cross-Account Transfer', () => {
  let eventBridgeClientCore: EventBridgeClient;
  let sqsClientRps: SQSClient;
  let queueUrl: string;

  beforeAll(async () => {
    // Initialize clients
    eventBridgeClientCore = new EventBridgeClient({
      region: REGION,
      // Assume role for Core Account if needed
    });

    sqsClientRps = new SQSClient({
      region: REGION,
      // Assume role for RPS Account if needed
    });

    // Get queue URL
    queueUrl = `https://sqs.${REGION}.amazonaws.com/${ACCOUNT_RPS_ID}/${QUEUE_NAME}`;

    // Purge queue to ensure clean state
    try {
      await sqsClientRps.send(
        new PurgeQueueCommand({
          QueueUrl: queueUrl,
        }),
      );
      // Wait for purge to complete
      await new Promise((resolve) => setTimeout(resolve, 60000));
    } catch (error) {
      console.log('Queue purge not needed or failed:', error);
    }
  });

  afterAll(async () => {
    eventBridgeClientCore.destroy();
    sqsClientRps.destroy();
  });

  test('Should transfer S3 ObjectCreated event from Core Account to RPS Account', async () => {
    const testBucketName = `${PREFIX}-core-test-bucket-${ACCOUNT_CORE_ID}-${REGION}`;
    const testObjectKey = 'input/test-file.txt';
    const testEventId = `test-${Date.now()}`;

    // Step 1: Send test event to Core Account's EventBridge
    const putEventsCommand = new PutEventsCommand({
      Entries: [
        {
          Source: 'aws.s3',
          DetailType: 'Object Created',
          Detail: JSON.stringify({
            'version': '0',
            'bucket': {
              name: testBucketName,
            },
            'object': {
              key: testObjectKey,
              size: 1024,
            },
            'request-id': testEventId,
            'requester': 'test-integration',
          }),
          Resources: [
            `arn:aws:s3:::${testBucketName}/${testObjectKey}`,
          ],
        },
      ],
    });

    const putResult = await eventBridgeClientCore.send(putEventsCommand);

    expect(putResult.FailedEntryCount).toBe(0);
    expect(putResult.Entries?.[0]?.EventId).toBeDefined();

    console.log(`Event sent to Core Account: ${putResult.Entries?.[0]?.EventId}`);

    // Step 2: Poll RPS Account's SQS queue for the event (max 2 minutes)
    let messageReceived = false;
    let attempts = 0;
    const maxAttempts = 24; // 2 minutes with 5-second intervals

    while (!messageReceived && attempts < maxAttempts) {
      attempts++;

      const receiveCommand = new ReceiveMessageCommand({
        QueueUrl: queueUrl,
        MaxNumberOfMessages: 10,
        WaitTimeSeconds: 5,
        MessageAttributeNames: ['All'],
      });

      const receiveResult = await sqsClientRps.send(receiveCommand);

      if (receiveResult.Messages && receiveResult.Messages.length > 0) {
        for (const message of receiveResult.Messages) {
          const body = JSON.parse(message.Body || '{}');

          // Check if this is our test event
          if (
            body.detail &&
            body.detail['request-id'] === testEventId
          ) {
            messageReceived = true;

            // Verify event structure
            expect(body.source).toBe('aws.s3');
            expect(body['detail-type']).toBe('Object Created');
            expect(body.account).toBe(ACCOUNT_CORE_ID);
            expect(body.detail.bucket.name).toBe(testBucketName);
            expect(body.detail.object.key).toBe(testObjectKey);

            console.log('Event successfully received in RPS Account');

            // Clean up: Delete the message
            await sqsClientRps.send(
              new DeleteMessageCommand({
                QueueUrl: queueUrl,
                ReceiptHandle: message.ReceiptHandle,
              }),
            );

            break;
          }
        }
      }

      if (!messageReceived) {
        console.log(`Attempt ${attempts}/${maxAttempts}: Message not yet received`);
        await new Promise((resolve) => setTimeout(resolve, 5000));
      }
    }

    expect(messageReceived).toBe(true);
  }, 180000); // 3-minute timeout
});
