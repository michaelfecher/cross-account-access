import { App } from 'aws-cdk-lib';
import { Template } from 'aws-cdk-lib/assertions';
import { StackCore } from '../src/stack-core';
import { StackRps } from '../src/stack-rps';

describe('Core Stack', () => {
  test('Creates S3 bucket with proper configuration', () => {
    const app = new App();
    const stack = new StackCore(app, 'TestStackCore', {
      prefix: 'test',
      accountRpsId: '222222222222',
      region: 'eu-central-1',
      env: { account: '111111111111', region: 'eu-central-1' },
    });

    const template = Template.fromStack(stack);

    // Verify S3 bucket exists
    template.hasResourceProperties('AWS::S3::Bucket', {
      BucketEncryption: {
        ServerSideEncryptionConfiguration: [
          {
            ServerSideEncryptionByDefault: {
              SSEAlgorithm: 'aws:kms',
            },
          },
        ],
      },
      VersioningConfiguration: {
        Status: 'Enabled',
      },
    });

    // Verify EventBridge rule exists
    template.hasResourceProperties('AWS::Events::Rule', {
      EventPattern: {
        'source': ['aws.s3'],
        'detail-type': ['Object Created'],
      },
    });
  });

  test('Uses RETAIN removal policy for production environments', () => {
    const app = new App();
    const stack = new StackCore(app, 'TestStackCore', {
      prefix: 'prod',
      accountRpsId: '222222222222',
      region: 'eu-central-1',
      env: { account: '111111111111', region: 'eu-central-1' },
    });

    const template = Template.fromStack(stack);

    // KMS key should have RETAIN policy for prod
    template.hasResource('AWS::KMS::Key', {
      DeletionPolicy: 'Retain',
      UpdateReplacePolicy: 'Retain',
    });
  });

  test('Uses DESTROY removal policy for dev environments', () => {
    const app = new App();
    const stack = new StackCore(app, 'TestStackCore', {
      prefix: 'dev',
      accountRpsId: '222222222222',
      region: 'eu-central-1',
      env: { account: '111111111111', region: 'eu-central-1' },
    });

    const template = Template.fromStack(stack);

    // KMS key should have DELETE policy for dev
    template.hasResource('AWS::KMS::Key', {
      DeletionPolicy: 'Delete',
      UpdateReplacePolicy: 'Delete',
    });
  });

  test('Validates required props', () => {
    const app = new App();

    // Empty prefix should throw
    expect(() => {
      new StackCore(app, 'TestInvalidPrefix', {
        prefix: '',
        accountRpsId: '222222222222',
        region: 'eu-central-1',
        env: { account: '111111111111', region: 'eu-central-1' },
      });
    }).toThrow('prefix is required');

    // Invalid account ID should throw
    expect(() => {
      new StackCore(app, 'TestInvalidAccount', {
        prefix: 'test',
        accountRpsId: 'invalid',
        region: 'eu-central-1',
        env: { account: '111111111111', region: 'eu-central-1' },
      });
    }).toThrow('12-digit AWS account ID');

    // Empty region should throw
    expect(() => {
      new StackCore(app, 'TestInvalidRegion', {
        prefix: 'test',
        accountRpsId: '222222222222',
        region: '',
        env: { account: '111111111111', region: 'eu-central-1' },
      });
    }).toThrow('region is required');
  });

  test('Uses AccountPrincipal for dev environments', () => {
    const app = new App();
    const stack = new StackCore(app, 'TestStackCore', {
      prefix: 'dev',
      accountRpsId: '222222222222',
      region: 'eu-central-1',
      env: { account: '111111111111', region: 'eu-central-1' },
    });

    const template = Template.fromStack(stack);

    // Bucket policy should use account principal for dev
    template.hasResourceProperties('AWS::S3::BucketPolicy', {
      PolicyDocument: {
        Statement: [{}, {}, {
          Sid: 'AllowAccountRpsLambdaRead',
          Principal: {
            AWS: '222222222222',
          },
        }],
      },
    });
  });
});

describe('RPS Stack', () => {
  test('Creates Lambda function with SQS trigger', () => {
    const app = new App();
    const stack = new StackRps(app, 'TestStackRps', {
      prefix: 'test',
      accountCoreId: '111111111111',
      stackCoreBucketName: 'test-bucket',
      region: 'eu-central-1',
      env: { account: '222222222222', region: 'eu-central-1' },
    });

    const template = Template.fromStack(stack);

    // Verify SQS queue exists
    template.hasResourceProperties('AWS::SQS::Queue', {
      QueueName: 'test-processor-queue',
    });

    // Verify Lambda function exists
    template.hasResourceProperties('AWS::Lambda::Function', {
      Runtime: 'nodejs22.x',
      FunctionName: 'test-s3-processor',
    });

    // Verify EventBridge rule for cross-account events
    template.hasResourceProperties('AWS::Events::Rule', {
      EventPattern: {
        'account': ['111111111111'],
        'source': ['aws.s3'],
        'detail-type': ['Object Created'],
      },
    });
  });

  test('Uses RETAIN removal policy for production environments', () => {
    const app = new App();
    const stack = new StackRps(app, 'TestStackRps', {
      prefix: 'prod',
      accountCoreId: '111111111111',
      stackCoreBucketName: 'prod-bucket',
      region: 'eu-central-1',
      env: { account: '222222222222', region: 'eu-central-1' },
    });

    const template = Template.fromStack(stack);

    // KMS key should have RETAIN policy for prod
    template.hasResource('AWS::KMS::Key', {
      DeletionPolicy: 'Retain',
      UpdateReplacePolicy: 'Retain',
    });
  });

  test('Uses DESTROY removal policy for dev environments', () => {
    const app = new App();
    const stack = new StackRps(app, 'TestStackRps', {
      prefix: 'dev',
      accountCoreId: '111111111111',
      stackCoreBucketName: 'dev-bucket',
      region: 'eu-central-1',
      env: { account: '222222222222', region: 'eu-central-1' },
    });

    const template = Template.fromStack(stack);

    // KMS key should have DELETE policy for dev
    template.hasResource('AWS::KMS::Key', {
      DeletionPolicy: 'Delete',
      UpdateReplacePolicy: 'Delete',
    });
  });

  test('Validates required props', () => {
    const app = new App();

    // Empty prefix should throw
    expect(() => {
      new StackRps(app, 'TestInvalidPrefix', {
        prefix: '',
        accountCoreId: '111111111111',
        stackCoreBucketName: 'test-bucket',
        region: 'eu-central-1',
        env: { account: '222222222222', region: 'eu-central-1' },
      });
    }).toThrow('prefix is required');

    // Invalid account ID should throw
    expect(() => {
      new StackRps(app, 'TestInvalidAccount', {
        prefix: 'test',
        accountCoreId: 'invalid',
        stackCoreBucketName: 'test-bucket',
        region: 'eu-central-1',
        env: { account: '222222222222', region: 'eu-central-1' },
      });
    }).toThrow('12-digit AWS account ID');

    // Invalid deploymentPrefix should throw
    expect(() => {
      new StackRps(app, 'TestInvalidDeployment', {
        prefix: 'test',
        accountCoreId: '111111111111',
        stackCoreBucketName: 'test-bucket',
        region: 'eu-central-1',
        deploymentPrefix: 'invalid/path',
        env: { account: '222222222222', region: 'eu-central-1' },
      });
    }).toThrow('must not contain');
  });

  test('Handles deployment prefix correctly', () => {
    const app = new App();
    const stack = new StackRps(app, 'TestStackRps', {
      prefix: 'dev',
      accountCoreId: '111111111111',
      stackCoreBucketName: 'dev-bucket',
      region: 'eu-central-1',
      deploymentPrefix: 'john',
      env: { account: '222222222222', region: 'eu-central-1' },
    });

    const template = Template.fromStack(stack);

    // Queue name should include deployment prefix
    template.hasResourceProperties('AWS::SQS::Queue', {
      QueueName: 'dev-john-processor-queue',
    });

    // Lambda should include deployment prefix
    template.hasResourceProperties('AWS::Lambda::Function', {
      FunctionName: 'dev-john-s3-processor',
      Environment: {
        Variables: {
          CDK_DEPLOYMENT_PREFIX: 'john',
        },
      },
    });

    // EventBridge rule should filter by deployment prefix path
    template.hasResourceProperties('AWS::Events::Rule', {
      EventPattern: {
        detail: {
          object: {
            key: [{
              prefix: 'input/john/',
            }],
          },
        },
      },
    });
  });
});