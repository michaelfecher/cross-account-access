import { App, Aspects } from 'aws-cdk-lib';
import { AwsSolutionsChecks } from 'cdk-nag';
import { StackCore } from './stack-core';
import { StackRps } from './stack-rps';

const app = new App();

// Apply CDK NAG checks
Aspects.of(app).add(new AwsSolutionsChecks({ verbose: true }));

// Single deployment configuration - set via environment variables
// Deploy each stack separately using different AWS profiles:
//   cdk deploy dev-StackCore --profile core-account
//   cdk deploy dev-StackRps --profile rps-account
const prefix = process.env.CDK_DEPLOYMENT_PREFIX || 'dev';
const region = process.env.REGION || 'eu-west-1';

const accountCoreId = process.env.ACCOUNT_CORE_ID || '111111111111';
const accountRpsId = process.env.ACCOUNT_RPS_ID || '222222222222';

// S3 prefixes for input and output files (configurable)
const inputPrefix = process.env.INPUT_PREFIX || 'input/';
const outputPrefix = process.env.OUTPUT_PREFIX || 'output/';

// Deploy RPS Stack (target account with Lambda processor)
// Note: Bucket name is predictable, so we construct it instead of cross-account reference
const stackCoreBucketName = `${prefix}-core-test-bucket-${accountCoreId}-${region}`;

// Deploy Core Stack (source account with S3 bucket)
const stackCore = new StackCore(app, `${prefix}-StackCore`, {
  prefix,
  accountRpsId,
  region,
  inputPrefix,
  env: {
    account: accountCoreId,
    region,
  },
  stackName: `${prefix}-core-stack`,
  description: `Core Stack for ${prefix}: S3 bucket with EventBridge notifications`,
});

const stackRps = new StackRps(app, `${prefix}-StackRps`, {
  prefix,
  accountCoreId,
  stackCoreBucketName,
  region,
  inputPrefix,
  outputPrefix,
  env: {
    account: accountRpsId,
    region,
  },
  stackName: `${prefix}-rps-stack`,
  description: `RPS Stack for ${prefix}: Lambda processor with SQS and EventBridge`,
});

app.synth();
