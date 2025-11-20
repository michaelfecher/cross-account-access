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
});