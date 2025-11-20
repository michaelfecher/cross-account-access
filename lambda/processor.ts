import { SQSEvent, SQSRecord, SQSBatchResponse, SQSBatchItemFailure } from 'aws-lambda';
import { S3Client, GetObjectCommand, PutObjectCommand } from '@aws-sdk/client-s3';

const s3Client = new S3Client({});
const BUCKET_NAME = process.env.BUCKET_NAME!;
const PREFIX = process.env.PREFIX!;

interface S3EventDetail {
  bucket: {
    name: string;
  };
  object: {
    key: string;
    size: number;
  };
  'request-id': string;
}

interface EventBridgeEvent {
  version: string;
  id: string;
  'detail-type': string;
  source: string;
  account: string;
  time: string;
  region: string;
  resources: string[];
  detail: S3EventDetail;
}

export const handler = async (event: SQSEvent): Promise<SQSBatchResponse> => {
  console.log('Processing SQS event:', JSON.stringify(event, null, 2));

  const batchItemFailures: SQSBatchItemFailure[] = [];

  for (const record of event.Records) {
    try {
      await processRecord(record);
      console.log(`Successfully processed record: ${record.messageId}`);
    } catch (error) {
      console.error(`Failed to process record: ${record.messageId}`, error);
      batchItemFailures.push({
        itemIdentifier: record.messageId,
      });
    }
  }

  return {
    batchItemFailures,
  };
};

async function processRecord(record: SQSRecord): Promise<void> {
  // Parse the EventBridge event from SQS message
  const eventBridgeEvent: EventBridgeEvent = JSON.parse(record.body);

  console.log('EventBridge event:', JSON.stringify(eventBridgeEvent, null, 2));

  const { bucket, object } = eventBridgeEvent.detail;
  const sourceKey = object.key;

  if (!sourceKey.startsWith('input/')) {
    console.warn(`Skipping object not in input/ prefix: ${sourceKey}`);
    return;
  }

  console.log(`Processing file: ${sourceKey} from bucket: ${bucket.name}`);

  // Read the file from input/ prefix
  const getObjectCommand = new GetObjectCommand({
    Bucket: BUCKET_NAME,
    Key: sourceKey,
  });

  const response = await s3Client.send(getObjectCommand);

  if (!response.Body) {
    throw new Error(`No body in S3 object: ${sourceKey}`);
  }

  // Convert stream to string
  const fileContent = await streamToString(response.Body);

  console.log(`Read ${fileContent.length} bytes from ${sourceKey}`);

  // Process the file (simple transformation example)
  const processedContent = processFileContent(fileContent, sourceKey);

  // Write the processed file to output/ prefix
  const outputKey = sourceKey.replace('input/', 'output/');

  const putObjectCommand = new PutObjectCommand({
    Bucket: BUCKET_NAME,
    Key: outputKey,
    Body: processedContent,
    ContentType: response.ContentType || 'text/plain',
    Metadata: {
      sourceKey,
      processedBy: PREFIX,
      processedAt: new Date().toISOString(),
    },
  });

  await s3Client.send(putObjectCommand);

  console.log(`Successfully wrote processed file to: ${outputKey}`);
}

function processFileContent(content: string, sourceKey: string): string {
  // Example processing: add metadata header
  const timestamp = new Date().toISOString();
  const header = `# Processed by ${PREFIX} at ${timestamp}\n# Source: ${sourceKey}\n\n`;

  return header + content;
}

async function streamToString(stream: any): Promise<string> {
  const chunks: Uint8Array[] = [];

  return new Promise((resolve, reject) => {
    stream.on('data', (chunk: Uint8Array) => chunks.push(chunk));
    stream.on('error', reject);
    stream.on('end', () => resolve(Buffer.concat(chunks).toString('utf-8')));
  });
}
