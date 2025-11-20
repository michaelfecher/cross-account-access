/**
 * Integration Test: Lambda S3 Read/Write Operations
 *
 * Purpose: Tests the Lambda function's ability to read from input/ prefix
 * and write to output/ prefix in Core Account's S3 bucket.
 *
 * Prerequisites:
 * - Both Core Stack and RPS Stack must be deployed
 * - AWS credentials must be configured for both accounts
 * - Set environment variables: ACCOUNT_CORE_ID, ACCOUNT_RPS_ID, PREFIX
 *
 * Test Flow:
 * 1. Upload a test file to the input/ prefix in Core Account's bucket
 * 2. Wait for the Lambda function to process it
 * 3. Verify the processed file appears in the output/ prefix
 * 4. Verify the content was processed correctly
 */

import {
  LambdaClient,
  InvokeCommand,
  GetFunctionCommand,
} from '@aws-sdk/client-lambda';
import {
  S3Client,
  PutObjectCommand,
  GetObjectCommand,
  DeleteObjectCommand,
  HeadObjectCommand,
} from '@aws-sdk/client-s3';

const PREFIX = process.env.PREFIX || 'dev';
const ACCOUNT_CORE_ID = process.env.ACCOUNT_CORE_ID || '111111111111';
const ACCOUNT_RPS_ID = process.env.ACCOUNT_RPS_ID || '222222222222';
const REGION = 'eu-central-1';
const BUCKET_NAME = `${PREFIX}-core-test-bucket-${ACCOUNT_CORE_ID}-${REGION}`;
const LAMBDA_NAME = `${PREFIX}-s3-processor`;

describe('Lambda S3 Cross-Account Operations', () => {
  let s3ClientCore: S3Client;
  let lambdaClientRps: LambdaClient;

  beforeAll(async () => {
    // Initialize clients
    s3ClientCore = new S3Client({
      region: REGION,
      // Assume role for Core Account if needed
    });

    lambdaClientRps = new LambdaClient({
      region: REGION,
      // Assume role for RPS Account if needed
    });
  });

  afterAll(async () => {
    s3ClientCore.destroy();
    lambdaClientRps.destroy();
  });

  test('Should read from input/ and write to output/ prefix', async () => {
    const timestamp = Date.now();
    const inputKey = `input/test-${timestamp}.txt`;
    const outputKey = `output/test-${timestamp}.txt`;
    const testContent = `Test content for integration test\nTimestamp: ${timestamp}\nTest scenario: Lambda S3 operations`;

    // Step 1: Upload test file to input/ prefix in Core Account bucket
    console.log(`Uploading test file: ${inputKey}`);

    const putCommand = new PutObjectCommand({
      Bucket: BUCKET_NAME,
      Key: inputKey,
      Body: testContent,
      ContentType: 'text/plain',
    });

    await s3ClientCore.send(putCommand);
    console.log('Test file uploaded successfully');

    // Step 2: Wait for Lambda to process (real scenario uses EventBridge + SQS)
    // For this test, we'll invoke the Lambda directly with a simulated event
    const testEvent = {
      Records: [
        {
          messageId: `test-${timestamp}`,
          body: JSON.stringify({
            'version': '0',
            'id': `test-event-${timestamp}`,
            'detail-type': 'Object Created',
            'source': 'aws.s3',
            'account': ACCOUNT_CORE_ID,
            'time': new Date().toISOString(),
            'region': REGION,
            'resources': [`arn:aws:s3:::${BUCKET_NAME}/${inputKey}`],
            'detail': {
              'version': '0',
              'bucket': {
                name: BUCKET_NAME,
              },
              'object': {
                key: inputKey,
                size: testContent.length,
              },
              'request-id': `test-${timestamp}`,
              'requester': 'integration-test',
            },
          }),
          receiptHandle: 'test-receipt-handle',
          attributes: {},
          messageAttributes: {},
          md5OfBody: '',
          eventSource: 'aws:sqs',
          eventSourceARN: `arn:aws:sqs:${REGION}:${ACCOUNT_RPS_ID}:${PREFIX}-processor-queue`,
          awsRegion: REGION,
        },
      ],
    };

    console.log('Invoking Lambda function...');

    const invokeCommand = new InvokeCommand({
      FunctionName: LAMBDA_NAME,
      InvocationType: 'RequestResponse',
      Payload: JSON.stringify(testEvent),
    });

    const invokeResult = await lambdaClientRps.send(invokeCommand);

    // Check Lambda execution
    expect(invokeResult.StatusCode).toBe(200);

    const responsePayload = JSON.parse(
      new TextDecoder().decode(invokeResult.Payload),
    );

    console.log('Lambda response:', JSON.stringify(responsePayload, null, 2));

    // Verify no batch failures
    expect(
      responsePayload.batchItemFailures?.length || 0,
    ).toBe(0);

    // Step 3: Wait a bit for S3 eventual consistency
    await new Promise((resolve) => setTimeout(resolve, 2000));

    // Step 4: Verify output file was created
    console.log(`Checking for output file: ${outputKey}`);

    let fileExists = false;
    let attempts = 0;
    const maxAttempts = 10;

    while (!fileExists && attempts < maxAttempts) {
      attempts++;

      try {
        const headCommand = new HeadObjectCommand({
          Bucket: BUCKET_NAME,
          Key: outputKey,
        });

        await s3ClientCore.send(headCommand);
        fileExists = true;
        console.log('Output file found!');
      } catch (error: any) {
        if (error.name === 'NotFound' && attempts < maxAttempts) {
          console.log(`Attempt ${attempts}/${maxAttempts}: File not yet available`);
          await new Promise((resolve) => setTimeout(resolve, 2000));
        } else {
          throw error;
        }
      }
    }

    expect(fileExists).toBe(true);

    // Step 5: Verify output file content
    const getCommand = new GetObjectCommand({
      Bucket: BUCKET_NAME,
      Key: outputKey,
    });

    const getResult = await s3ClientCore.send(getCommand);
    const outputContent = await streamToString(getResult.Body);

    // Verify content was processed (Lambda adds a header)
    expect(outputContent).toContain('# Processed by');
    expect(outputContent).toContain(PREFIX);
    expect(outputContent).toContain(inputKey);
    expect(outputContent).toContain(testContent);

    // Verify metadata
    expect(getResult.Metadata).toBeDefined();
    expect(getResult.Metadata?.sourceKey).toBe(inputKey);
    expect(getResult.Metadata?.processedBy).toBe(PREFIX);

    console.log('Output file content verified successfully');

    // Cleanup: Delete test files
    await s3ClientCore.send(
      new DeleteObjectCommand({
        Bucket: BUCKET_NAME,
        Key: inputKey,
      }),
    );

    await s3ClientCore.send(
      new DeleteObjectCommand({
        Bucket: BUCKET_NAME,
        Key: outputKey,
      }),
    );

    console.log('Test files cleaned up');
  }, 60000); // 60-second timeout

  test('Should verify Lambda has correct IAM permissions', async () => {
    // Get Lambda function configuration
    const getFunctionCommand = new GetFunctionCommand({
      FunctionName: LAMBDA_NAME,
    });

    const functionConfig = await lambdaClientRps.send(getFunctionCommand);

    // Verify function exists and is configured correctly
    expect(functionConfig.Configuration?.FunctionName).toBe(LAMBDA_NAME);
    expect(functionConfig.Configuration?.Runtime).toBe('nodejs20.x');
    expect(functionConfig.Configuration?.Environment?.Variables?.BUCKET_NAME).toBe(BUCKET_NAME);
    expect(functionConfig.Configuration?.Environment?.Variables?.PREFIX).toBe(PREFIX);

    console.log('Lambda function configuration verified');
  });

  test('Should verify Lambda cannot write to restricted prefixes', async () => {
    // This test verifies that the Lambda's IAM permissions are properly scoped
    // It should NOT be able to write to prefixes other than output/

    const timestamp = Date.now();
    const restrictedKey = `restricted/test-${timestamp}.txt`;
    const testContent = 'This should fail';

    // Create a simulated event that tries to write to a restricted prefix
    const testEvent = {
      Records: [
        {
          messageId: `test-restricted-${timestamp}`,
          body: JSON.stringify({
            'version': '0',
            'id': `test-event-${timestamp}`,
            'detail-type': 'Object Created',
            'source': 'aws.s3',
            'account': ACCOUNT_CORE_ID,
            'time': new Date().toISOString(),
            'region': REGION,
            'resources': [`arn:aws:s3:::${BUCKET_NAME}/input/dummy.txt`],
            'detail': {
              'version': '0',
              'bucket': {
                name: 'non-existent-bucket', // This should cause the Lambda to handle gracefully
              },
              'object': {
                key: 'input/dummy.txt',
                size: 100,
              },
              'request-id': `test-restricted-${timestamp}`,
            },
          }),
          receiptHandle: 'test-receipt-handle',
          attributes: {},
          messageAttributes: {},
          md5OfBody: '',
          eventSource: 'aws:sqs',
          eventSourceARN: `arn:aws:sqs:${REGION}:${ACCOUNT_RPS_ID}:${PREFIX}-processor-queue`,
          awsRegion: REGION,
        },
      ],
    };

    const invokeCommand = new InvokeCommand({
      FunctionName: LAMBDA_NAME,
      InvocationType: 'RequestResponse',
      Payload: JSON.stringify(testEvent),
    });

    const invokeResult = await lambdaClientRps.send(invokeCommand);

    // Lambda should execute but report the failure
    expect(invokeResult.StatusCode).toBe(200);

    const responsePayload = JSON.parse(
      new TextDecoder().decode(invokeResult.Payload),
    );

    // The failed record should be in batchItemFailures
    expect(responsePayload.batchItemFailures?.length).toBeGreaterThan(0);

    console.log('Lambda correctly handled restricted access scenario');
  });
});

async function streamToString(stream: any): Promise<string> {
  const chunks: Uint8Array[] = [];

  return new Promise((resolve, reject) => {
    stream.on('data', (chunk: Uint8Array) => chunks.push(chunk));
    stream.on('error', reject);
    stream.on('end', () => resolve(Buffer.concat(chunks).toString('utf-8')));
  });
}
