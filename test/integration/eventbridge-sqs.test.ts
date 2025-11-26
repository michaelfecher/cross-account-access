/**
 * Integration Test: EventBridge to SQS Integration
 *
 * Purpose: Tests the integration between EventBridge rule in RPS Account
 * and the SQS queue that triggers the Lambda function.
 *
 * Prerequisites:
 * - RPS Stack must be deployed
 * - AWS credentials must be configured for RPS Account
 * - Set environment variables: ACCOUNT_RPS_ID, PREFIX
 *
 * Test Flow:
 * 1. Send a test event directly to RPS Account's EventBridge
 * 2. Verify the event is routed to the SQS queue
 * 3. Verify message format and attributes
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

describe('EventBridge to SQS Integration in RPS Account', () => {
  let eventBridgeClient: EventBridgeClient;
  let sqsClient: SQSClient;
  let queueUrl: string;

  beforeAll(async () => {
    // Initialize clients for RPS Account
    eventBridgeClient = new EventBridgeClient({
      region: REGION,
      // Assume role for RPS Account if needed
    });

    sqsClient = new SQSClient({
      region: REGION,
      // Assume role for RPS Account if needed
    });

    // Get queue URL
    queueUrl = `https://sqs.${REGION}.amazonaws.com/${ACCOUNT_RPS_ID}/${QUEUE_NAME}`;

    // Purge queue to ensure clean state
    try {
      await sqsClient.send(
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
    eventBridgeClient.destroy();
    sqsClient.destroy();
  });

  test('Should route S3 event from EventBridge to SQS queue', async () => {
    const testBucketName = `${PREFIX}-core-input-bucket-${ACCOUNT_CORE_ID}-${REGION}`;
    const testObjectKey = 'integration-test.txt';
    const testEventId = `sqs-test-${Date.now()}`;

    // Step 1: Send test event to RPS Account's EventBridge (simulating cross-account event)
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
              size: 2048,
            },
            'request-id': testEventId,
            'requester': 'integration-test-sqs',
          }),
          Resources: [`arn:aws:s3:::${testBucketName}/${testObjectKey}`],
          // Simulate event from Core Account
          // Note: In real scenario, this would be sent from Core Account
        },
      ],
    });

    const putResult = await eventBridgeClient.send(putEventsCommand);

    expect(putResult.FailedEntryCount).toBe(0);
    console.log(`Event sent to EventBridge: ${putResult.Entries?.[0]?.EventId}`);

    // Step 2: Poll SQS queue for the message (max 1 minute)
    let messageReceived = false;
    let attempts = 0;
    const maxAttempts = 12; // 1 minute with 5-second intervals

    while (!messageReceived && attempts < maxAttempts) {
      attempts++;

      const receiveCommand = new ReceiveMessageCommand({
        QueueUrl: queueUrl,
        MaxNumberOfMessages: 10,
        WaitTimeSeconds: 5,
        MessageAttributeNames: ['All'],
        AttributeNames: ['All'],
      });

      const receiveResult = await sqsClient.send(receiveCommand);

      if (receiveResult.Messages && receiveResult.Messages.length > 0) {
        for (const message of receiveResult.Messages) {
          const body = JSON.parse(message.Body || '{}');

          // Check if this is our test event
          if (body.detail && body.detail['request-id'] === testEventId) {
            messageReceived = true;

            // Verify message structure
            expect(body.source).toBe('aws.s3');
            expect(body['detail-type']).toBe('Object Created');
            expect(body.detail.bucket.name).toBe(testBucketName);
            expect(body.detail.object.key).toBe(testObjectKey);

            // Verify SQS message attributes
            expect(message.MessageId).toBeDefined();
            expect(message.Body).toBeDefined();

            console.log('Message successfully received in SQS queue');
            console.log(`Message ID: ${message.MessageId}`);

            // Clean up: Delete the message
            await sqsClient.send(
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
        console.log(`Attempt ${attempts}/${maxAttempts}: Message not yet in queue`);
        await new Promise((resolve) => setTimeout(resolve, 5000));
      }
    }

    expect(messageReceived).toBe(true);
  }, 90000); // 90-second timeout

  test('Should verify SQS queue configuration', async () => {
    // Verify queue attributes
    const getAttributesCommand = new GetQueueAttributesCommand({
      QueueUrl: queueUrl,
      AttributeNames: ['All'],
    });

    const attributes = await sqsClient.send(getAttributesCommand);

    // Verify encryption is enabled
    expect(attributes.Attributes?.KmsMasterKeyId).toBeDefined();

    // Verify DLQ is configured
    expect(attributes.Attributes?.RedrivePolicy).toBeDefined();

    const redrivePolicy = JSON.parse(attributes.Attributes?.RedrivePolicy || '{}');
    expect(redrivePolicy.maxReceiveCount).toBe(3);
    expect(redrivePolicy.deadLetterTargetArn).toContain('processor-dlq');

    console.log('SQS queue configuration verified successfully');
  });
});
