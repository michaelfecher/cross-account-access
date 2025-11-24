import * as path from 'path';
import * as cdk from 'aws-cdk-lib';
import * as events from 'aws-cdk-lib/aws-events';
import * as targets from 'aws-cdk-lib/aws-events-targets';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as kms from 'aws-cdk-lib/aws-kms';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as lambdaEventSources from 'aws-cdk-lib/aws-lambda-event-sources';
import * as nodejs from 'aws-cdk-lib/aws-lambda-nodejs';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as sqs from 'aws-cdk-lib/aws-sqs';
import * as cr from 'aws-cdk-lib/custom-resources';
import { NagSuppressions } from 'cdk-nag';
import { Construct } from 'constructs';

export interface StackRpsProps extends cdk.StackProps {
  readonly prefix: string;
  readonly accountCoreId: string;
  readonly stackCoreBucketName: string;
  readonly region: string;
  readonly inputPrefix?: string; // S3 prefix for input files (default: 'input/')
  readonly outputPrefix?: string; // S3 prefix for output files (default: 'output/')
  readonly deploymentPrefix?: string; // Optional deployment-specific subdirectory (e.g., 'john' → 'input/john/')
  readonly existingEventBusName?: string; // If provided, use shared event bus (for multi-deployment dev environments)
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
      deploymentPrefix,
      existingEventBusName,
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

    // Resource naming: include deployment prefix for isolation
    // - Without deployment prefix: dev-processor-queue
    // - With deployment prefix: dev-john-processor-queue
    const resourcePrefix = deploymentPrefix ? `${prefix}-${deploymentPrefix}` : prefix;

    // Create Dead Letter Queue
    const dlq = new sqs.Queue(this, 'ProcessorDLQ', {
      queueName: `${resourcePrefix}-processor-dlq`,
      encryption: sqs.QueueEncryption.KMS,
      encryptionMasterKey: queueKey,
      enforceSSL: true,
      retentionPeriod: cdk.Duration.days(14),
    });

    // Create main processing queue
    this.processorQueue = new sqs.Queue(this, 'ProcessorQueue', {
      queueName: `${resourcePrefix}-processor-queue`,
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
      roleName: `${resourcePrefix}-processor-lambda-role`,
      assumedBy: new iam.ServicePrincipal('lambda.amazonaws.com'),
      description: `Lambda role for ${resourcePrefix} S3 processor`,
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
          `arn:aws:logs:${region}:${this.account}:log-group:/aws/lambda/${resourcePrefix}-s3-processor`,
          `arn:aws:logs:${region}:${this.account}:log-group:/aws/lambda/${resourcePrefix}-s3-processor:*`,
        ],
      }),
    );

    // Grant Lambda access to read from input prefix and write to output prefix in Core Stack bucket
    lambdaRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'ReadFromStackCoreBucket',
        effect: iam.Effect.ALLOW,
        actions: ['s3:GetObject', 's3:ListBucket'],
        resources: [
          `arn:aws:s3:::${stackCoreBucketName}`,
          `arn:aws:s3:::${stackCoreBucketName}/${inputPrefix}*`,
        ],
      }),
    );

    lambdaRole.addToPolicy(
      new iam.PolicyStatement({
        sid: 'WriteToStackCoreBucket',
        effect: iam.Effect.ALLOW,
        actions: ['s3:PutObject', 's3:PutObjectAcl'],
        resources: [`arn:aws:s3:::${stackCoreBucketName}/${outputPrefix}*`],
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
              `arn:aws:s3:::${stackCoreBucketName}/${inputPrefix}*`,
              `arn:aws:s3:::${stackCoreBucketName}/${outputPrefix}*`,
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
      functionName: `${resourcePrefix}-s3-processor`,
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
        ...(deploymentPrefix && { CDK_DEPLOYMENT_PREFIX: deploymentPrefix }),
        POWERTOOLS_SERVICE_NAME: `${resourcePrefix}-processor`,
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

    // ========================================
    // Custom Event Bus Setup (Multi-Deployment Support)
    // ========================================
    // Use Custom Resource for idempotent event bus creation to support shared bus in dev environments.
    // This allows multiple deployments (dev-alice, dev-bob) to deploy separate stacks to the same RPS
    // Dev account while sharing a single custom event bus. Without this Custom Resource approach:
    // - First deployment to deploy would succeed (creates bus)
    // - Second deployment would fail (bus already exists - ResourceAlreadyExistsException)
    // - Manual setup steps would be required (creates deployment friction)
    //
    // With Custom Resource + ignoreErrorCodesMatching:
    // - First deployment creates the bus (onCreate succeeds)
    // - Subsequent deployments reuse existing bus (ResourceAlreadyExistsException ignored)
    // - No race conditions or manual prerequisites
    // - Shared resource survives individual stack deletions (intentionally no onDelete)
    const eventBusName = existingEventBusName || `${prefix}-cross-account-bus`;

    const ensureEventBus = new cr.AwsCustomResource(this, 'EnsureEventBus', {
      onCreate: {
        service: 'EventBridge',
        action: 'createEventBus',
        parameters: { Name: eventBusName },
        physicalResourceId: cr.PhysicalResourceId.of(eventBusName),
        ignoreErrorCodesMatching: 'ResourceAlreadyExistsException', // Idempotent!
      },
      onUpdate: {
        service: 'EventBridge',
        action: 'createEventBus',
        parameters: { Name: eventBusName },
        physicalResourceId: cr.PhysicalResourceId.of(eventBusName),
        ignoreErrorCodesMatching: 'ResourceAlreadyExistsException',
      },
      // onDelete intentionally empty - preserve shared resource for other deployments
      policy: cr.AwsCustomResourcePolicy.fromSdkCalls({
        resources: [`arn:aws:events:${region}:${this.account}:event-bus/${eventBusName}`],
      }),
      logRetention: logs.RetentionDays.ONE_WEEK,
    });

    // Reference the event bus (either newly created or existing shared bus)
    // Using IEventBus (imported) rather than EventBus because:
    // - The bus might have been created by another stack (shared dev environment)
    // - We can't use addToResourcePolicy() on imported resources (IEventBus limitation)
    // - That's why we use Custom Resource below for permission granting
    this.eventBus = events.EventBus.fromEventBusName(
      this,
      'CrossAccountEventBus',
      eventBusName,
    ) as events.EventBus;

    // Grant Core Account permission to put events on custom event bus using Custom Resource
    // Why Custom Resource instead of this.eventBus.addToResourcePolicy()?
    // - If using shared bus (existingEventBusName provided), this.eventBus is IEventBus (imported)
    // - IEventBus doesn't have addToResourcePolicy() method (only concrete EventBus class does)
    // - Custom Resource works regardless of whether bus is newly created or imported
    // - Allows consistent permission management across all deployment scenarios
    //
    // StatementId includes deployment prefix to avoid conflicts when sharing bus:
    // - Regular dev: "AllowCoreAccount-dev"
    // - John's stack: "AllowCoreAccount-dev-john"
    const permissionStatementId = deploymentPrefix
      ? `AllowCoreAccount-${prefix}-${deploymentPrefix}`
      : `AllowCoreAccount-${prefix}`;

    const grantCoreAccountPermission = new cr.AwsCustomResource(this, 'GrantCoreAccountPermission', {
      onCreate: {
        service: 'EventBridge',
        action: 'putPermission',
        parameters: {
          EventBusName: eventBusName,
          StatementId: permissionStatementId,
          Action: 'events:PutEvents',
          Principal: accountCoreId,
        },
        physicalResourceId: cr.PhysicalResourceId.of(`${eventBusName}-permission-${permissionStatementId}`),
        ignoreErrorCodesMatching: 'ResourceAlreadyExistsException',
      },
      onUpdate: {
        service: 'EventBridge',
        action: 'putPermission',
        parameters: {
          EventBusName: eventBusName,
          StatementId: permissionStatementId,
          Action: 'events:PutEvents',
          Principal: accountCoreId,
        },
        physicalResourceId: cr.PhysicalResourceId.of(`${eventBusName}-permission-${permissionStatementId}`),
        ignoreErrorCodesMatching: 'ResourceAlreadyExistsException',
      },
      onDelete: {
        service: 'EventBridge',
        action: 'removePermission',
        parameters: {
          EventBusName: eventBusName,
          StatementId: permissionStatementId,
        },
        ignoreErrorCodesMatching: 'ResourceNotFoundException',
      },
      policy: cr.AwsCustomResourcePolicy.fromSdkCalls({
        resources: [`arn:aws:events:${region}:${this.account}:event-bus/${eventBusName}`],
      }),
      logRetention: logs.RetentionDays.ONE_WEEK,
    });

    // Ensure permission is granted after bus exists
    grantCoreAccountPermission.node.addDependency(ensureEventBus);

    // Create EventBridge rule to receive events from Core Account
    // Multi-deployment isolation via optional deployment prefix:
    // - With deploymentPrefix='john': filters by "input/john/" → processes only john's files
    // - Without deploymentPrefix: filters by "input/" → processes all input/ events
    //   (Lambda will skip subdirectories to avoid processing other deployments' files)
    const objectKeyPrefix = deploymentPrefix ? `${inputPrefix}${deploymentPrefix}/` : inputPrefix;

    const s3EventRule = new events.Rule(this, 'S3EventFromCoreAccount', {
      ruleName: `${resourcePrefix}-receive-s3-events`,
      description: deploymentPrefix
        ? `Receives S3 events from Core Account for ${resourcePrefix} (filters by ${objectKeyPrefix})`
        : `Receives S3 events from Core Account for ${resourcePrefix} (processes ${inputPrefix} root files only)`,
      eventBus: this.eventBus,
      eventPattern: {
        account: [accountCoreId],
        source: ['aws.s3'],
        detailType: ['Object Created'],
        detail: {
          bucket: {
            name: [stackCoreBucketName],
          },
          object: {
            key: [{ prefix: objectKeyPrefix }],
          },
        },
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

    // Suppress CDK NAG warnings for Custom Resource Lambda providers
    // These Lambdas are created by AWS CDK for Custom Resources and use AWS managed policies
    NagSuppressions.addResourceSuppressions(
      ensureEventBus,
      [
        {
          id: 'AwsSolutions-IAM4',
          reason: 'Custom Resource Lambda provider uses AWS managed policy for CloudWatch Logs (CDK-generated)',
          appliesTo: ['Policy::arn:<AWS::Partition>:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole'],
        },
      ],
      true,
    );

    NagSuppressions.addResourceSuppressions(
      grantCoreAccountPermission,
      [
        {
          id: 'AwsSolutions-IAM4',
          reason: 'Custom Resource Lambda provider uses AWS managed policy for CloudWatch Logs (CDK-generated)',
          appliesTo: ['Policy::arn:<AWS::Partition>:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole'],
        },
      ],
      true,
    );

    // Suppress IAM warnings for log retention Custom Resource (CDK-managed)
    // The LogRetention construct creates a Lambda that manages CloudWatch log retention
    NagSuppressions.addStackSuppressions(this, [
      {
        id: 'AwsSolutions-IAM4',
        reason: 'Log Retention Lambda uses AWS managed policy (CDK-generated construct)',
        appliesTo: ['Policy::arn:<AWS::Partition>:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole'],
      },
      {
        id: 'AwsSolutions-IAM5',
        reason: 'Log Retention Lambda needs wildcard permissions to manage log groups across the stack',
        appliesTo: ['Resource::*'],
      },
    ]);

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

    // Outputs - use resourcePrefix for unique export names
    new cdk.CfnOutput(this, 'QueueUrl', {
      value: this.processorQueue.queueUrl,
      description: 'URL of the processor queue',
      exportName: `${resourcePrefix}-StackRps-QueueUrl`,
    });

    new cdk.CfnOutput(this, 'LambdaArn', {
      value: this.processorLambda.functionArn,
      description: 'ARN of the processor Lambda',
      exportName: `${resourcePrefix}-StackRps-LambdaArn`,
    });

    new cdk.CfnOutput(this, 'EventBusArn', {
      value: this.eventBus.eventBusArn,
      description: 'ARN of the custom event bus for cross-account events',
      exportName: `${resourcePrefix}-StackRps-EventBusArn`,
    });

    new cdk.CfnOutput(this, 'EventBusName', {
      value: this.eventBus.eventBusName,
      description: 'Name of the custom event bus',
      exportName: `${resourcePrefix}-StackRps-EventBusName`,
    });
  }
}
