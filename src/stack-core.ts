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
  public readonly inputBucket: s3.IBucket;
  public readonly outputBucket: s3.IBucket;
  public readonly inputBucketName: string;
  public readonly outputBucketName: string;
  public readonly s3AccessRole: iam.IRole;
  public readonly s3AccessRoleArn: string;

  constructor(scope: Construct, id: string, props: StackCoreProps) {
    super(scope, id, props);

    const { prefix, accountRpsId, region } = props;

    // Validate required props
    if (!prefix || prefix.trim().length === 0) {
      throw new Error('StackCore: prefix is required and cannot be empty');
    }
    if (!/^\d{12}$/.test(accountRpsId)) {
      throw new Error(`StackCore: accountRpsId must be a 12-digit AWS account ID, got: ${accountRpsId}`);
    }
    if (!region || region.trim().length === 0) {
      throw new Error('StackCore: region is required and cannot be empty');
    }

    // Security: Different principal strategies based on environment
    // - Dev: Wildcard pattern matching processor Lambda roles only
    //   Allows: dev-processor-lambda-role, dev-john-processor-lambda-role, dev-alice-processor-lambda-role
    //   Denies: Any other role in RPS account (dev-other-service-role, etc.)
    // - Preprod/Prod: Specific role ARN only (no deployment prefixes allowed)
    const isDev = prefix.toLowerCase().includes('dev');

    const rpsPrincipal = isDev
      ? new iam.CompositePrincipal(
        // Allow base deployment role (e.g., dev-processor-lambda-role)
        new iam.ArnPrincipal(`arn:aws:iam::${accountRpsId}:role/${prefix}-processor-lambda-role`),
        // Allow deployment-specific roles (e.g., dev-john-processor-lambda-role, dev-alice-processor-lambda-role)
        new iam.ArnPrincipal(`arn:aws:iam::${accountRpsId}:role/${prefix}-*-processor-lambda-role`),
      )
      : new iam.ArnPrincipal(`arn:aws:iam::${accountRpsId}:role/${prefix}-processor-lambda-role`); // Prod: Specific role only

    // Environment-based retention policies
    // Dev: DESTROY (cost optimization, easy cleanup)
    // Prod: RETAIN (data protection, compliance)
    const removalPolicy = isDev ? cdk.RemovalPolicy.DESTROY : cdk.RemovalPolicy.RETAIN;

    // Create KMS key for S3 bucket encryption with predictable alias
    const bucketKey = new kms.Key(this, 'BucketKey', {
      alias: `alias/${prefix}-bucket-key`,
      description: `KMS key for ${prefix} S3 bucket encryption`,
      enableKeyRotation: true,
      removalPolicy,
    });

    // KMS permissions are now granted to S3AccessRole (see below after bucket creation)
    // No direct cross-account KMS key policy needed

    // Create access logs bucket
    const accessLogsBucket = new s3.Bucket(this, 'AccessLogsBucket', {
      bucketName: `${prefix}-core-test-access-logs-${this.account}-${region}`,
      encryption: s3.BucketEncryption.S3_MANAGED,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      enforceSSL: true,
      versioned: false,
      removalPolicy,
      autoDeleteObjects: isDev, // Only auto-delete in dev
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

    // Create input S3 bucket with security best practices
    this.inputBucket = new s3.Bucket(this, 'InputBucket', {
      bucketName: `${prefix}-core-input-bucket-${this.account}-${region}`,
      encryption: s3.BucketEncryption.KMS,
      encryptionKey: bucketKey,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      versioned: true,
      enforceSSL: true,
      serverAccessLogsBucket: accessLogsBucket,
      serverAccessLogsPrefix: 'input-bucket-logs/',
      removalPolicy,
      autoDeleteObjects: isDev, // Only auto-delete in dev
      eventBridgeEnabled: true, // Enable EventBridge notifications
      lifecycleRules: [
        {
          id: 'DeleteOldVersions',
          noncurrentVersionExpiration: cdk.Duration.days(30),
        },
      ],
    });

    this.inputBucketName = this.inputBucket.bucketName;

    // Create output S3 bucket with security best practices
    this.outputBucket = new s3.Bucket(this, 'OutputBucket', {
      bucketName: `${prefix}-core-output-bucket-${this.account}-${region}`,
      encryption: s3.BucketEncryption.KMS,
      encryptionKey: bucketKey,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      versioned: true,
      enforceSSL: true,
      serverAccessLogsBucket: accessLogsBucket,
      serverAccessLogsPrefix: 'output-bucket-logs/',
      removalPolicy,
      autoDeleteObjects: isDev, // Only auto-delete in dev
      eventBridgeEnabled: false, // No events needed for output bucket
      lifecycleRules: [
        {
          id: 'DeleteOldVersions',
          noncurrentVersionExpiration: cdk.Duration.days(30),
        },
      ],
    });

    this.outputBucketName = this.outputBucket.bucketName;

    // Create S3 Access Role in Core Account for RPS Lambda to assume
    // This centralizes all S3 permissions in the Core account
    // Note: Wildcards in ARNs aren't supported in IAM trust policies, so we use StringLike condition
    this.s3AccessRole = new iam.Role(this, 'S3AccessRole', {
      roleName: `${prefix}-s3-access-role`,
      description: `Role for RPS Lambda to access ${prefix} S3 bucket via AssumeRole`,
      // Trust policy: Allow RPS Lambda roles to assume this role
      assumedBy: isDev
        ? new iam.AccountPrincipal(accountRpsId) // Placeholder for dev, will be customized below
        : new iam.ArnPrincipal(`arn:aws:iam::${accountRpsId}:role/${prefix}-processor-lambda-role`), // Prod: Specific role only
      maxSessionDuration: cdk.Duration.hours(1),
    });

    // For dev: Add StringLike condition to restrict which roles can assume
    // Allows: dev-processor-lambda-role, dev-john-processor-lambda-role, dev-alice-processor-lambda-role
    // Denies: Any other role in RPS account
    if (isDev) {
      const cfnRole = this.s3AccessRole.node.defaultChild as iam.CfnRole;
      cfnRole.assumeRolePolicyDocument = {
        Version: '2012-10-17',
        Statement: [
          {
            Effect: 'Allow',
            Principal: {
              AWS: `arn:aws:iam::${accountRpsId}:root`, // AccountPrincipal format
            },
            Action: 'sts:AssumeRole',
            Condition: {
              StringLike: {
                'aws:PrincipalArn': [
                  `arn:aws:iam::${accountRpsId}:role/${prefix}-processor-lambda-role`, // Base role
                  `arn:aws:iam::${accountRpsId}:role/${prefix}-*-processor-lambda-role`, // Deployment-specific roles
                ],
              },
            },
          },
        ],
      };
    }

    this.s3AccessRoleArn = this.s3AccessRole.roleArn;

    // Grant S3 permissions to the S3AccessRole (adds to role policy, NOT bucket policy)
    // Since role is in same account as buckets, no bucket policy needed
    this.inputBucket.grantRead(this.s3AccessRole); // Read entire input bucket
    this.outputBucket.grantWrite(this.s3AccessRole); // Write entire output bucket

    // Grant KMS permissions to the S3AccessRole (shared key for both buckets)
    bucketKey.grantDecrypt(this.s3AccessRole);
    bucketKey.grantEncryptDecrypt(this.s3AccessRole);

    // Explicit deny for public access (defense in depth)
    // Only allows: Core account (S3AccessRole is in this account)
    this.inputBucket.addToResourcePolicy(
      new iam.PolicyStatement({
        sid: 'DenyPublicAccess',
        effect: iam.Effect.DENY,
        principals: [new iam.AnyPrincipal()],
        actions: ['s3:*'],
        resources: [
          this.inputBucket.bucketArn,
          `${this.inputBucket.bucketArn}/*`,
        ],
        conditions: {
          Bool: {
            'aws:PrincipalIsAWSService': 'false',
          },
          StringNotEquals: {
            'aws:PrincipalAccount': [this.account], // Only Core account
          },
        },
      }),
    );

    this.outputBucket.addToResourcePolicy(
      new iam.PolicyStatement({
        sid: 'DenyPublicAccess',
        effect: iam.Effect.DENY,
        principals: [new iam.AnyPrincipal()],
        actions: ['s3:*'],
        resources: [
          this.outputBucket.bucketArn,
          `${this.outputBucket.bucketArn}/*`,
        ],
        conditions: {
          Bool: {
            'aws:PrincipalIsAWSService': 'false',
          },
          StringNotEquals: {
            'aws:PrincipalAccount': [this.account], // Only Core account
          },
        },
      }),
    );

    // Create EventBridge rule for S3 ObjectCreated events on input bucket
    const s3EventRule = new events.Rule(this, 'S3InputEventRule', {
      ruleName: `${prefix}-s3-input-events`,
      description: `Captures S3 ObjectCreated events for ${prefix} input bucket`,
      eventPattern: {
        source: ['aws.s3'],
        detailType: ['Object Created'],
        detail: {
          bucket: {
            name: [this.inputBucket.bucketName],
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
      this.inputBucket,
      [
        {
          id: 'AwsSolutions-S5',
          reason:
            'Input bucket policy includes defense-in-depth deny for public access',
        },
      ],
      true,
    );

    NagSuppressions.addResourceSuppressions(
      this.outputBucket,
      [
        {
          id: 'AwsSolutions-S5',
          reason:
            'Output bucket policy includes defense-in-depth deny for public access',
        },
      ],
      true,
    );

    // Suppress IAM5 for S3AccessRole - wildcard permissions are necessary for S3 bucket access
    NagSuppressions.addResourceSuppressions(
      this.s3AccessRole,
      [
        {
          id: 'AwsSolutions-IAM5',
          reason: 'S3 wildcard permissions required for bucket access (read input bucket, write output bucket)',
          appliesTo: [
            'Action::s3:GetBucket*',
            'Action::s3:GetObject*',
            'Action::s3:List*',
            'Action::s3:Abort*',
            'Action::s3:DeleteObject*',
            { regex: '/Resource::<InputBucket.*\\.Arn>/\\*/g' },
            { regex: '/Resource::<OutputBucket.*\\.Arn>/\\*/g' },
          ],
        },
        {
          id: 'AwsSolutions-IAM5',
          reason: 'KMS wildcard permissions required for S3 encryption operations',
          appliesTo: [
            'Action::kms:GenerateDataKey*',
            'Action::kms:ReEncrypt*',
          ],
        },
      ],
      true,
    );

    // Outputs
    new cdk.CfnOutput(this, 'InputBucketName', {
      value: this.inputBucket.bucketName,
      description: 'Name of the input S3 bucket',
      exportName: `${prefix}-StackCore-InputBucketName`,
    });

    new cdk.CfnOutput(this, 'InputBucketArn', {
      value: this.inputBucket.bucketArn,
      description: 'ARN of the input S3 bucket',
      exportName: `${prefix}-StackCore-InputBucketArn`,
    });

    new cdk.CfnOutput(this, 'OutputBucketName', {
      value: this.outputBucket.bucketName,
      description: 'Name of the output S3 bucket',
      exportName: `${prefix}-StackCore-OutputBucketName`,
    });

    new cdk.CfnOutput(this, 'OutputBucketArn', {
      value: this.outputBucket.bucketArn,
      description: 'ARN of the output S3 bucket',
      exportName: `${prefix}-StackCore-OutputBucketArn`,
    });

    new cdk.CfnOutput(this, 'S3AccessRoleArn', {
      value: this.s3AccessRole.roleArn,
      description: 'ARN of the S3 access role for RPS Lambda to assume',
      exportName: `${prefix}-StackCore-S3AccessRoleArn`,
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
