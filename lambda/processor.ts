import { SQSEvent, SQSRecord, SQSBatchResponse, SQSBatchItemFailure } from 'aws-lambda';
import { S3Client, GetObjectCommand, PutObjectCommand } from '@aws-sdk/client-s3';
import { STSClient, AssumeRoleCommand, Credentials } from '@aws-sdk/client-sts';

const stsClient = new STSClient({});
const INPUT_BUCKET_NAME = process.env.INPUT_BUCKET_NAME!;
const OUTPUT_BUCKET_NAME = process.env.OUTPUT_BUCKET_NAME!;
const PREFIX = process.env.PREFIX!;
const CDK_DEPLOYMENT_PREFIX = process.env.CDK_DEPLOYMENT_PREFIX; // Optional: for deployment-specific isolation
const CORE_S3_ACCESS_ROLE_ARN = process.env.CORE_S3_ACCESS_ROLE_ARN!; // Core account role to assume

// Cache credentials to avoid repeated AssumeRole calls
// Lambda container is reused, so this cache persists across invocations
let cachedCredentials: Credentials | null = null;
let credentialsExpiration: Date | null = null;

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

/**
 * Get S3 client with assumed Core account role credentials
 * Caches credentials to avoid repeated AssumeRole calls
 */
async function getS3ClientWithAssumedRole(): Promise<S3Client> {
  const now = new Date();

  // Check if cached credentials are still valid (with 5-minute buffer)
  if (cachedCredentials && credentialsExpiration) {
    const bufferMs = 5 * 60 * 1000; // 5 minutes
    if (now.getTime() < credentialsExpiration.getTime() - bufferMs) {
      console.log('Using cached credentials');
      return new S3Client({
        credentials: {
          accessKeyId: cachedCredentials.AccessKeyId!,
          secretAccessKey: cachedCredentials.SecretAccessKey!,
          sessionToken: cachedCredentials.SessionToken!,
        },
      });
    }
  }

  // Assume role to get temporary credentials
  console.log(`Assuming role: ${CORE_S3_ACCESS_ROLE_ARN}`);
  const assumeRoleCommand = new AssumeRoleCommand({
    RoleArn: CORE_S3_ACCESS_ROLE_ARN,
    RoleSessionName: `lambda-${PREFIX}-${Date.now()}`,
    DurationSeconds: 3600, // 1 hour
  });

  const assumeRoleResponse = await stsClient.send(assumeRoleCommand);

  if (!assumeRoleResponse.Credentials) {
    throw new Error('Failed to assume role: No credentials returned');
  }

  // Cache credentials
  cachedCredentials = assumeRoleResponse.Credentials;
  credentialsExpiration = assumeRoleResponse.Credentials.Expiration!;
  console.log(`Assumed role successfully. Credentials expire at: ${credentialsExpiration.toISOString()}`);

  // Return S3 client with assumed role credentials
  return new S3Client({
    credentials: {
      accessKeyId: cachedCredentials.AccessKeyId!,
      secretAccessKey: cachedCredentials.SecretAccessKey!,
      sessionToken: cachedCredentials.SessionToken!,
    },
  });
}

export const handler = async (event: SQSEvent): Promise<SQSBatchResponse> => {
  console.log('Processing SQS event:', JSON.stringify(event, null, 2));

  // Get S3 client with assumed role credentials (cached across invocations)
  const s3Client = await getS3ClientWithAssumedRole();

  const batchItemFailures: SQSBatchItemFailure[] = [];

  for (const record of event.Records) {
    try {
      await processRecord(record, s3Client);
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

async function processRecord(record: SQSRecord, s3Client: S3Client): Promise<void> {
  // Parse the EventBridge event from SQS message
  const eventBridgeEvent: EventBridgeEvent = JSON.parse(record.body);

  console.log('EventBridge event:', JSON.stringify(eventBridgeEvent, null, 2));

  const { bucket, object } = eventBridgeEvent.detail;
  const sourceKey = object.key;

  console.log(`Processing file: ${sourceKey} from input bucket: ${bucket.name}`);

  // Read the file from input bucket
  const getObjectCommand = new GetObjectCommand({
    Bucket: INPUT_BUCKET_NAME,
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

  // Write the processed file to output bucket with same key
  const outputKey = sourceKey;

  const putObjectCommand = new PutObjectCommand({
    Bucket: OUTPUT_BUCKET_NAME,
    Key: outputKey,
    Body: processedContent,
    ContentType: response.ContentType || 'text/plain',
    Metadata: {
      sourceKey,
      processedBy: CDK_DEPLOYMENT_PREFIX ? `${PREFIX}-${CDK_DEPLOYMENT_PREFIX}` : PREFIX,
      processedAt: new Date().toISOString(),
    },
  });

  await s3Client.send(putObjectCommand);

  console.log(`Successfully wrote processed file to output bucket: ${OUTPUT_BUCKET_NAME}/${outputKey}`);
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
