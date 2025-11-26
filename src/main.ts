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
//
// Architecture:
//   - Core account has separate input and output S3 buckets
//   - Lambda reads from input bucket, writes to output bucket
//   - Files keep the same key (no prefix transformations)
const prefix = process.env.STAGE || 'dev';
const region = process.env.REGION || 'eu-west-1';

const accountCoreId = process.env.ACCOUNT_CORE_ID || '111111111111';
const accountRpsId = process.env.ACCOUNT_RPS_ID || '222222222222';

// Optional: Deployment prefix for multi-developer isolation
const developerPrefix = process.env.CDK_DEPLOYMENT_PREFIX;

// Optional: Existing event bus name for shared dev environments (multi-developer)
// If provided, multiple developers can share a single event bus instead of creating individual ones
const existingEventBusName = process.env.EXISTING_EVENT_BUS_NAME;

// Construct bucket names (predictable naming, no cross-account references needed)
const stackCoreInputBucketName = `${prefix}-core-input-bucket-${accountCoreId}-${region}`;
const stackCoreOutputBucketName = `${prefix}-core-output-bucket-${accountCoreId}-${region}`;

// Deploy Core Stack (source account with S3 buckets)
const stackCore = new StackCore(app, `${prefix}-StackCore`, {
  prefix,
  accountRpsId,
  region,
  env: {
    account: accountCoreId,
    region,
  },
  stackName: `${prefix}-core-stack`,
  description: `Core Stack for ${prefix}: Input/output S3 buckets with EventBridge notifications`,
});

// Construct stack ID and name based on deployment prefix
// With deployment prefix: dev-john-StackRps, dev-john-rps-stack
// Without deployment prefix: dev-StackRps, dev-rps-stack
const rpsStackId = developerPrefix ? `${prefix}-${developerPrefix}-StackRps` : `${prefix}-StackRps`;
const rpsStackName = developerPrefix ? `${prefix}-${developerPrefix}-rps-stack` : `${prefix}-rps-stack`;

const stackRps = new StackRps(app, rpsStackId, {
  prefix,
  deploymentPrefix: developerPrefix,
  accountCoreId,
  stackCoreInputBucketName,
  stackCoreOutputBucketName,
  region,
  existingEventBusName,
  env: {
    account: accountRpsId,
    region,
  },
  stackName: rpsStackName,
  description: developerPrefix
    ? `RPS Stack for ${prefix}-${developerPrefix}: Lambda processor with SQS and EventBridge`
    : `RPS Stack for ${prefix}: Lambda processor with SQS and EventBridge`,
});

app.synth();
