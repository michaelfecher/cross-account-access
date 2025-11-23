import * as path from 'path';
import * as cdk from 'aws-cdk-lib';
import * as events from 'aws-cdk-lib/aws-events';
import * as targets from 'aws-cdk-lib/aws-events-targets';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as kms from 'aws-cdk-lib/aws-kms';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as lambdaEventSources from 'aws-cdk-lib/aws-lambda-event-sources';
import * as nodejs from 'aws-cdk-lib/aws-lambda-nodejs';
import * as sqs from 'aws-cdk-lib/aws-sqs';
import { NagSuppressions } from 'cdk-nag';
import { Construct } from 'constructs';

export interface StackRpsProps extends cdk.StackProps {
  readonly prefix: string;
  readonly accountCoreId: string;
  readonly stackCoreBucketName: string;
  readonly region: string;
  readonly inputPrefix?: string;   // S3 prefix for input files (default: 'input/')
  readonly outputPrefix?: string;  // S3 prefix for output files (default: 'output/')
}

export class StackRps extends cdk.Stack {
  public readonly processorQueue: sqs.IQueue;
  public readonly processorLambda: lambda.IFunction;
  public readonly eventBus: events.EventBus;

  constructor(scope: Construct, id: string, props: StackRpsProps) {
    super(scope, id, props);

    const {
      prefix,
      accountCoreId,
      stackCoreBucketName,
      region,
      inputPrefix = 'input/',
      outputPrefix = 'output/',
    } = props;

    // Create KMS key for SQS encryption
    const queueKey = new kms.Key(this, 'QueueKey', {
      description: `KMS key for ${prefix} SQS queue encryption`,
      enableKeyRotation: true,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // Grant EventBridge permission to use the KMS key for encrypting SQS messages
    queueKey.addToResourcePolicy(
      new iam.PolicyStatement({
        sid: 'AllowEventBridgeToEncrypt',
        effect: iam.Effect.ALLOW,
        principals: [new iam.ServicePrincipal('events.amazonaws.com')],
        actions: [
          'kms:Decrypt',
          'kms:GenerateDataKey',
        ],
        resources: ['*'],
      }),
    );

    // Create Dead Letter Queue
    const dlq = new sqs.Queue(this, 'ProcessorDLQ', {
      queueName: `${prefix}-processor-dlq`,
      encryption: sqs.QueueEncryption.KMS,
      encryptionMasterKey: queueKey,
      enforceSSL: true,
      retentionPeriod: cdk.Duration.days(14),
    });

    // Create main processing queue
    this.processorQueue = new sqs.Queue(this, 'ProcessorQueue', {
      queueName: `${prefix}-processor-queue`,
      encryption: sqs.QueueEncryption.KMS,
      encryptionMasterKey: queueKey,
      enforceSSL: true,
      visibilityTimeout: cdk.Duration.seconds(300),
      retentionPeriod: cdk.Duration.days(4),
      deadLetterQueue: {
        queue: dlq,
        maxReceiveCount: 3,
      },
    });

    // Create IAM role for Lambda with specific name for cross-account access
    const lambdaRole = new iam.Role(this, 'ProcessorLambdaRole', {
      roleName: `${prefix}-processor-lambda-role`,
      assumedBy: new iam.ServicePrincipal('lambda.amazonaws.com'),
      description: `Lambda role for ${prefix} S3 processor`,
    });

    // CloudWatch Logs permissions (replaces AWSLambdaBasicExecutionRole)
    // Scoped to specific log group instead of using AWS managed policy
    lambdaRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'CloudWatchLogs',
        effect: iam.Effect.ALLOW,
        actions: [
          'logs:CreateLogGroup',
          'logs:CreateLogStream',
          'logs:PutLogEvents',
        ],
        resources: [
          `arn:aws:logs:${region}:${this.account}:log-group:/aws/lambda/${prefix}-s3-processor`,
          `arn:aws:logs:${region}:${this.account}:log-group:/aws/lambda/${prefix}-s3-processor:*`,
        ],
      }),
    );

    // Grant Lambda access to read from input/ and write to output/ in Core Stack bucket
    lambdaRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'ReadFromStackCoreBucket',
        effect: iam.Effect.ALLOW,
        actions: ['s3:GetObject', 's3:ListBucket'],
        resources: [
          `arn:aws:s3:::${stackCoreBucketName}`,
          `arn:aws:s3:::${stackCoreBucketName}/input/*`,
        ],
      }),
    );

    lambdaRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'WriteToStackCoreBucket',
        effect: iam.Effect.ALLOW,
        actions: ['s3:PutObject', 's3:PutObjectAcl'],
        resources: [`arn:aws:s3:::${stackCoreBucketName}/output/*`],
      }),
    );

    // Grant Lambda access to KMS key for encryption/decryption (cross-account)
    // Restricted to: Core account keys only, via S3 service, for specific bucket prefixes
    lambdaRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'DecryptStackCoreBucket',
        effect: iam.Effect.ALLOW,
        actions: [
          'kms:Decrypt',
          'kms:DescribeKey',
          'kms:GenerateDataKey', // Required for writing to encrypted S3
        ],
        resources: [
          `arn:aws:kms:${region}:${accountCoreId}:key/*`,
        ],
        conditions: {
          StringEquals: {
            'kms:ViaService': `s3.${region}.amazonaws.com`,
          },
          StringLike: {
            'kms:EncryptionContext:aws:s3:arn': [
              `arn:aws:s3:::${stackCoreBucketName}/input/*`,
              `arn:aws:s3:::${stackCoreBucketName}/output/*`,
            ],
          },
        },
      }),
    );

    // Grant Lambda access to SQS queue
    lambdaRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'AccessSQSQueue',
        effect: iam.Effect.ALLOW,
        actions: [
          'sqs:ReceiveMessage',
          'sqs:DeleteMessage',
          'sqs:GetQueueAttributes',
          'sqs:ChangeMessageVisibility',
        ],
        resources: [this.processorQueue.queueArn],
      }),
    );

    // Grant Lambda access to KMS for SQS decryption
    queueKey.grantDecrypt(lambdaRole);

    // Create Lambda function
    this.processorLambda = new nodejs.NodejsFunction(this, 'ProcessorLambda', {
      functionName: `${prefix}-s3-processor`,
      runtime: lambda.Runtime.NODEJS_22_X,
      handler: 'handler',
      entry: path.join(__dirname, '../lambda/processor.ts'),
      timeout: cdk.Duration.seconds(60),
      memorySize: 512,
      role: lambdaRole,
      environment: {
        BUCKET_NAME: stackCoreBucketName,
        PREFIX: prefix,
        INPUT_PREFIX: inputPrefix,
        OUTPUT_PREFIX: outputPrefix,
        POWERTOOLS_SERVICE_NAME: `${prefix}-processor`,
        LOG_LEVEL: 'INFO',
      },
      bundling: {
        minify: true,
        sourceMap: true,
        externalModules: ['@aws-sdk/*'],
      },
    });

    // Add SQS event source to Lambda
    this.processorLambda.addEventSource(
      new lambdaEventSources.SqsEventSource(this.processorQueue, {
        batchSize: 10,
        maxBatchingWindow: cdk.Duration.seconds(5),
        reportBatchItemFailures: true,
      }),
    );

    // Create custom event bus (bypasses SCP restrictions on default bus)
    this.eventBus = new events.EventBus(this, 'CrossAccountEventBus', {
      eventBusName: `${prefix}-cross-account-bus`,
    });

    // Create EventBridge rule to receive events from Core Account
    const s3EventRule = new events.Rule(this, 'S3EventFromCoreAccount', {
      ruleName: `${prefix}-receive-s3-events`,
      description: `Receives S3 events from Core Account for ${prefix}`,
      eventBus: this.eventBus,
      eventPattern: {
        account: [accountCoreId],
        source: ['aws.s3'],
        detailType: ['Object Created'],
      },
    });

    // Add SQS queue as target for EventBridge rule
    s3EventRule.addTarget(new targets.SqsQueue(this.processorQueue));

    // Grant EventBridge rule permission to send to SQS (override CDK's restrictive condition)
    this.processorQueue.addToResourcePolicy(
      new iam.PolicyStatement({
        sid: 'AllowEventBridgeRuleSendMessage',
        effect: iam.Effect.ALLOW,
        principals: [new iam.ServicePrincipal('events.amazonaws.com')],
        actions: ['sqs:SendMessage'],
        resources: [this.processorQueue.queueArn],
        conditions: {
          ArnEquals: {
            'aws:SourceArn': s3EventRule.ruleArn,
          },
        },
      }),
    );

    // Grant Core Account EventBridge permission to put events on custom event bus
    this.eventBus.addToResourcePolicy(
      new iam.PolicyStatement({
        sid: `AllowCoreAccount-${prefix}`,
        effect: iam.Effect.ALLOW,
        principals: [new iam.AccountPrincipal(accountCoreId)],
        actions: ['events:PutEvents'],
        resources: [this.eventBus.eventBusArn],
      }),
    );

    // CDK Nag Suppressions for Lambda Role
    // No IAM4 suppression needed - using inline policy instead of AWS managed policy

    // Suppress CDK NAG warnings for stack-level resources
    // Note: Stack suppressions are necessary for DefaultPolicy which is auto-generated
    NagSuppressions.addStackSuppressions(this, [
      {
        id: 'AwsSolutions-IAM5',
        reason:
          'Wildcard permissions required for S3 prefix-based access (input/* and output/*), KMS keys in Core account (restricted by kms:ViaService and kms:EncryptionContext conditions), and CloudWatch Logs log streams',
        appliesTo: [
          {
            regex: '/^Resource::arn:aws:s3:::.*/input/\\*$/g',
          },
          {
            regex: '/^Resource::arn:aws:s3:::.*/output/\\*$/g',
          },
          {
            regex: '/^Resource::arn:aws:kms:.*:key/\\*$/g',
          },
          {
            regex: '/^Resource::arn:aws:logs:.*:log-group:/aws/lambda/.*:\\*$/g',
          },
        ],
      },
    ]);

    // Suppress EVB1 for event bus policy - restricted to specific Core account
    NagSuppressions.addResourceSuppressions(
      this.eventBus,
      [
        {
          id: 'AwsSolutions-EVB1',
          reason:
            'Event bus policy restricts access to specific Core account only for cross-account event routing',
        },
      ],
      true,
    );

    NagSuppressions.addResourceSuppressions(
      queueKey,
      [
        {
          id: 'AwsSolutions-KMS5',
          reason: 'KMS key rotation is enabled',
        },
      ],
      true,
    );

    // Outputs
    new cdk.CfnOutput(this, 'QueueUrl', {
      value: this.processorQueue.queueUrl,
      description: 'URL of the processor queue',
      exportName: `${prefix}-StackRps-QueueUrl`,
    });

    new cdk.CfnOutput(this, 'LambdaArn', {
      value: this.processorLambda.functionArn,
      description: 'ARN of the processor Lambda',
      exportName: `${prefix}-StackRps-LambdaArn`,
    });

    new cdk.CfnOutput(this, 'EventBusArn', {
      value: this.eventBus.eventBusArn,
      description: 'ARN of the custom event bus for cross-account events',
      exportName: `${prefix}-StackRps-EventBusArn`,
    });

    new cdk.CfnOutput(this, 'EventBusName', {
      value: this.eventBus.eventBusName,
      description: 'Name of the custom event bus',
      exportName: `${prefix}-StackRps-EventBusName`,
    });
  }
}
