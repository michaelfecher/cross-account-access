import * as cdk from 'aws-cdk-lib';
import * as events from 'aws-cdk-lib/aws-events';
import * as targets from 'aws-cdk-lib/aws-events-targets';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as kms from 'aws-cdk-lib/aws-kms';
import * as s3 from 'aws-cdk-lib/aws-s3';
import { NagSuppressions } from 'cdk-nag';
import { Construct } from 'constructs';

export interface StackCoreProps extends cdk.StackProps {
  readonly prefix: string;
  readonly accountRpsId: string;
  readonly region: string;
}

export class StackCore extends cdk.Stack {
  public readonly bucket: s3.IBucket;
  public readonly bucketName: string;

  constructor(scope: Construct, id: string, props: StackCoreProps) {
    super(scope, id, props);

    const { prefix, accountRpsId, region } = props;

    // Create KMS key for S3 bucket encryption with predictable alias
    const bucketKey = new kms.Key(this, 'BucketKey', {
      alias: `alias/${prefix}-bucket-key`,
      description: `KMS key for ${prefix} S3 bucket encryption`,
      enableKeyRotation: true,
      removalPolicy: cdk.RemovalPolicy.DESTROY, // For dev purposes
    });

    // Grant RPS Account Lambda role access to the KMS key for read and write
    // Using StringLike condition to allow any *-processor-lambda-role (multi-developer support)
    // Least-privilege: restricted to specific account + role naming pattern + S3 service only
    bucketKey.addToResourcePolicy(
      new iam.PolicyStatement({
        sid: 'AllowAccountRpsLambdaDecrypt',
        effect: iam.Effect.ALLOW,
        principals: [new iam.AccountPrincipal(accountRpsId)],
        actions: [
          'kms:Decrypt',
          'kms:DescribeKey',
          'kms:GenerateDataKey', // Required for writing to encrypted S3
        ],
        resources: ['*'],
        conditions: {
          StringEquals: {
            'kms:ViaService': `s3.${region}.amazonaws.com`,
          },
          StringLike: {
            'aws:PrincipalArn': `arn:aws:iam::${accountRpsId}:role/*-processor-lambda-role`,
          },
        },
      }),
    );

    // Create access logs bucket
    const accessLogsBucket = new s3.Bucket(this, 'AccessLogsBucket', {
      bucketName: `${prefix}-core-test-access-logs-${this.account}-${region}`,
      encryption: s3.BucketEncryption.S3_MANAGED,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      enforceSSL: true,
      versioned: false,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
      objectOwnership: s3.ObjectOwnership.BUCKET_OWNER_PREFERRED,
    });

    // Explicit deny for public access (defense in depth)
    accessLogsBucket.addToResourcePolicy(
      new iam.PolicyStatement({
        sid: 'DenyPublicAccess',
        effect: iam.Effect.DENY,
        principals: [new iam.AnyPrincipal()],
        actions: ['s3:*'],
        resources: [
          accessLogsBucket.bucketArn,
          `${accessLogsBucket.bucketArn}/*`,
        ],
        conditions: {
          Bool: {
            'aws:PrincipalIsAWSService': 'false',
          },
          StringNotEquals: {
            'aws:PrincipalAccount': this.account,
          },
        },
      }),
    );

    // Create main S3 bucket with security best practices
    this.bucket = new s3.Bucket(this, 'Bucket', {
      bucketName: `${prefix}-core-test-bucket-${this.account}-${region}`,
      encryption: s3.BucketEncryption.KMS,
      encryptionKey: bucketKey,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      versioned: true,
      enforceSSL: true,
      serverAccessLogsBucket: accessLogsBucket,
      serverAccessLogsPrefix: 'access-logs/',
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
      eventBridgeEnabled: true, // Enable EventBridge notifications
      lifecycleRules: [
        {
          id: 'DeleteOldVersions',
          noncurrentVersionExpiration: cdk.Duration.days(30),
        },
      ],
    });

    this.bucketName = this.bucket.bucketName;

    // Explicit deny for public access (defense in depth)
    // Allows: same account, RPS account, AWS services
    this.bucket.addToResourcePolicy(
      new iam.PolicyStatement({
        sid: 'DenyPublicAccess',
        effect: iam.Effect.DENY,
        principals: [new iam.AnyPrincipal()],
        actions: ['s3:*'],
        resources: [
          this.bucket.bucketArn,
          `${this.bucket.bucketArn}/*`,
        ],
        conditions: {
          Bool: {
            'aws:PrincipalIsAWSService': 'false',
          },
          StringNotEquals: {
            'aws:PrincipalAccount': [this.account, accountRpsId],
          },
        },
      }),
    );

    // Grant RPS Account Lambda role access to the bucket
    // Read access to input/* and write access to output/*
    // Using StringLike with wildcard for multi-developer support
    this.bucket.addToResourcePolicy(
      new iam.PolicyStatement({
        sid: 'AllowAccountRpsLambdaRead',
        effect: iam.Effect.ALLOW,
        principals: [new iam.AccountPrincipal(accountRpsId)],
        actions: ['s3:GetObject', 's3:ListBucket'],
        resources: [
          this.bucket.bucketArn,
          `${this.bucket.bucketArn}/input/*`,
        ],
        conditions: {
          StringLike: {
            'aws:PrincipalArn': `arn:aws:iam::${accountRpsId}:role/*-processor-lambda-role`,
          },
        },
      }),
    );

    this.bucket.addToResourcePolicy(
      new iam.PolicyStatement({
        sid: 'AllowAccountRpsLambdaWrite',
        effect: iam.Effect.ALLOW,
        principals: [new iam.AccountPrincipal(accountRpsId)],
        actions: ['s3:PutObject', 's3:PutObjectAcl'],
        resources: [`${this.bucket.bucketArn}/output/*`],
        conditions: {
          StringLike: {
            'aws:PrincipalArn': `arn:aws:iam::${accountRpsId}:role/*-processor-lambda-role`,
          },
        },
      }),
    );

    // Create EventBridge rule for S3 ObjectCreated events on input/ prefix
    const s3EventRule = new events.Rule(this, 'S3InputEventRule', {
      ruleName: `${prefix}-s3-input-events`,
      description: `Captures S3 ObjectCreated events for ${prefix} bucket input/ prefix`,
      eventPattern: {
        source: ['aws.s3'],
        detailType: ['Object Created'],
        detail: {
          bucket: {
            name: [this.bucket.bucketName],
          },
          object: {
            key: [{ prefix: 'input/' }],
          },
        },
      },
    });

    // Add target to send events to RPS Account's custom EventBridge bus
    const customEventBusName = `${prefix}-cross-account-bus`;
    const crossAccountEventBus = events.EventBus.fromEventBusArn(
      this,
      'AccountRpsEventBus',
      `arn:aws:events:${region}:${accountRpsId}:event-bus/${customEventBusName}`,
    );

    s3EventRule.addTarget(
      new targets.EventBus(crossAccountEventBus, {
        role: this.createCrossAccountEventBridgeRole(accountRpsId, region, prefix, customEventBusName),
      }),
    );

    // CDK Nag Suppressions
    NagSuppressions.addResourceSuppressions(
      bucketKey,
      [
        {
          id: 'AwsSolutions-KMS5',
          reason: 'KMS key rotation is enabled for production use',
        },
      ],
      true,
    );

    // Suppress CDK NAG warnings for BucketNotificationsHandler (created by eventBridgeEnabled)
    NagSuppressions.addStackSuppressions(this, [
      {
        id: 'AwsSolutions-IAM4',
        reason:
          'BucketNotificationsHandler Lambda uses AWS managed policy for CloudWatch Logs access',
        appliesTo: [
          'Policy::arn:<AWS::Partition>:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole',
        ],
      },
    ]);

    // Suppress S3 access logs bucket findings - it cannot log to itself
    NagSuppressions.addResourceSuppressions(
      accessLogsBucket,
      [
        {
          id: 'AwsSolutions-S1',
          reason: 'Access logs bucket cannot log to itself - would cause infinite loop',
        },
      ],
      true,
    );

    // Suppress S5 for buckets with cross-account access policies
    NagSuppressions.addResourceSuppressions(
      accessLogsBucket,
      [
        {
          id: 'AwsSolutions-S5',
          reason: 'Access logs bucket has no bucket policy - only receives logs from main bucket',
        },
      ],
      true,
    );

    NagSuppressions.addResourceSuppressions(
      this.bucket,
      [
        {
          id: 'AwsSolutions-S5',
          reason:
            'Bucket policy allows cross-account access from RPS Lambda with StringLike condition on role name pattern',
        },
      ],
      true,
    );

    // Outputs
    new cdk.CfnOutput(this, 'BucketName', {
      value: this.bucket.bucketName,
      description: 'Name of the S3 bucket',
      exportName: `${prefix}-StackCore-BucketName`,
    });

    new cdk.CfnOutput(this, 'BucketArn', {
      value: this.bucket.bucketArn,
      description: 'ARN of the S3 bucket',
      exportName: `${prefix}-StackCore-BucketArn`,
    });
  }

  private createCrossAccountEventBridgeRole(
    accountRpsId: string,
    region: string,
    prefix: string,
    eventBusName: string,
  ): iam.Role {
    const role = new iam.Role(this, 'CrossAccountEventBridgeRole', {
      roleName: `${prefix}-cross-account-eventbridge-role`,
      assumedBy: new iam.ServicePrincipal('events.amazonaws.com'),
      description: 'Role for EventBridge to send events to RPS Account',
    });

    role.addToPolicy(
      new iam.PolicyStatement({
        effect: iam.Effect.ALLOW,
        actions: ['events:PutEvents'],
        resources: [`arn:aws:events:${region}:${accountRpsId}:event-bus/${eventBusName}`],
      }),
    );

    NagSuppressions.addResourceSuppressions(
      role,
      [
        {
          id: 'AwsSolutions-IAM5',
          reason: 'Wildcard required for EventBridge cross-account event delivery',
        },
      ],
      true,
    );

    return role;
  }
}
