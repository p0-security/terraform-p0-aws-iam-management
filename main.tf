# Initialize account tracking file
resource "local_file" "account_tracker" {
  filename = "${path.module}/discovered_accounts.json"
  content  = jsonencode({
    accounts = [var.root_account_id]
  })
}

# Create the P0RoleIamManager role in the root account
resource "aws_iam_role" "root_role" {
  provider = aws.root
  name     = "P0RoleIamManager"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = "accounts.google.com"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "accounts.google.com:aud" = var.google_audience_id
          }
        }
      }
    ]
  })
}

# Create the inline policy for the root account role
resource "aws_iam_role_policy" "root_role_policy" {
  provider = aws.root
  name     = "P0RoleIamManagerPolicy"
  role     = aws_iam_role.root_role.id

  policy = templatefile("${path.module}/policies/p0_role_policy.json", {
    account_id = var.root_account_id
  })
}

# IAM role for Lambda
resource "aws_iam_role" "lambda_role" {
  provider = aws.root
  name     = "role-creation-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

# Lambda role policy
resource "aws_iam_role_policy" "lambda_role_policy" {
  provider = aws.root
  role     = aws_iam_role.lambda_role.id
  name     = "role-creation-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sts:AssumeRole",
          "organizations:ListAccounts",
          "organizations:DescribeOrganization", 
          "organizations:ListRoots",            
          "organizations:ListOrganizationalUnitsForParent", 
          "organizations:ListChildren",       
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "lambda:PublishLayerVersion",
          "lambda:GetLayerVersion",
          "lambda:DeleteLayerVersion"
        ]
        Resource = "*"
      }
    ]
  })
}

# Create lambda layer directory structure
resource "null_resource" "create_layer_dir" {
  provisioner "local-exec" {
    command = "mkdir -p lambda-layer/nodejs"
  }
}

# Create package.json for Lambda layer
resource "local_file" "layer_package_json" {
  depends_on = [null_resource.create_layer_dir]
  filename = "lambda-layer/nodejs/package.json"
  content = <<EOF
{
  "name": "role-manager-layer",
  "version": "1.0.0",
  "dependencies": {
    "@aws-sdk/client-sts": "^3.0.0",
    "@aws-sdk/client-iam": "^3.0.0",
    "@aws-sdk/client-organizations": "^3.0.0"
  }
}
EOF
}

# Install npm dependencies for layer
resource "null_resource" "layer_npm_install" {
  depends_on = [local_file.layer_package_json]

  provisioner "local-exec" {
    working_dir = "lambda-layer/nodejs"
    command     = "npm install --production"
  }
}

# Create the Lambda layer zip
data "archive_file" "lambda_layer" {
  type        = "zip"
  output_path = "lambda_layer.zip"
  source_dir  = "lambda-layer"
  
  depends_on = [
    null_resource.layer_npm_install
  ]
}

# Create Lambda layer
resource "aws_lambda_layer_version" "dependencies" {
  provider          = aws.root
  filename          = data.archive_file.lambda_layer.output_path
  layer_name        = "role-manager-dependencies"
  compatible_runtimes = ["nodejs18.x"]
  
  depends_on = [
    data.archive_file.lambda_layer
  ]
}

# Create lambda function directory
resource "null_resource" "create_lambda_dir" {
  provisioner "local-exec" {
    command = "mkdir -p lambda"
  }
}

# Copy the policy template to lambda directory
resource "local_file" "policy_template" {
  depends_on = [null_resource.create_lambda_dir]
  filename = "lambda/p0_role_policy.json"
  content  = file("${path.module}/policies/p0_role_policy.json")
}

# Create Lambda function code
resource "local_file" "lambda_source" {
  depends_on = [null_resource.create_lambda_dir]
  filename = "lambda/index.js"
  content = <<EOF
const { STSClient, AssumeRoleCommand } = require('@aws-sdk/client-sts');
const { IAMClient, CreateRoleCommand, PutRolePolicyCommand, DeleteRoleCommand, DeleteRolePolicyCommand } = require('@aws-sdk/client-iam');
const { OrganizationsClient, ListAccountsCommand } = require('@aws-sdk/client-organizations');
const fs = require('fs');
const path = require('path');

async function getOrganizationAccounts() {
  console.log('Starting getOrganizationAccounts function');
  try {
    const orgClient = new OrganizationsClient({ 
      region: 'us-east-1',
      logger: console  // Add logging
    });
    console.log('Created OrganizationsClient');
    
    const accounts = [];
    let nextToken;

    do {
      console.log('Sending ListAccountsCommand...');
      const command = new ListAccountsCommand({ NextToken: nextToken });
      console.log('Command created:', JSON.stringify(command));
      
      try {
        const response = await orgClient.send(command);
        console.log('Received response:', JSON.stringify(response));
        
        // Filter only ACTIVE accounts and exclude root account
        const activeAccounts = response.Accounts
          .filter(account => account.Status === 'ACTIVE' && account.Id !== process.env.ROOT_ACCOUNT_ID)
          .map(account => account.Id);
        
        accounts.push(...activeAccounts);
        nextToken = response.NextToken;
      } catch (sendError) {
        console.error('Error sending command:', sendError);
        console.error('Error details:', JSON.stringify(sendError, null, 2));
        throw sendError;
      }
    } while (nextToken);

    console.log('Final accounts list:', accounts);
    return accounts;
  } catch (error) {
    console.error('Error in getOrganizationAccounts:', error);
    console.error('Stack trace:', error.stack);
    throw error;
  }
}

async function cleanupAccount(accountId) {
  console.log('============================================');
  console.log('Starting cleanup for account:', accountId);
  const sts = new STSClient({ region: 'us-east-1' });
  
  try {
    // Assume OrganizationAccountAccessRole in member account
    console.log('Assuming OrganizationAccountAccessRole in account:', accountId);
    const assumeRoleCommand = new AssumeRoleCommand({
      RoleArn: "arn:aws:iam::" + accountId + ":role/OrganizationAccountAccessRole",
      RoleSessionName: 'CleanupMemberRole'
    });
    const assumeRole = await sts.send(assumeRoleCommand);
    console.log('Successfully assumed role in account:', accountId);
    
    // Create IAM client with temporary credentials
    const iam = new IAMClient({
      credentials: {
        accessKeyId: assumeRole.Credentials.AccessKeyId,
        secretAccessKey: assumeRole.Credentials.SecretAccessKey,
        sessionToken: assumeRole.Credentials.SessionToken
      },
      region: 'us-east-1'
    });
    
    // Delete the inline policy first
    console.log('Deleting inline policy from P0RoleIamManager in account:', accountId);
    try {
      const deleteRolePolicyCommand = new DeleteRolePolicyCommand({
        RoleName: 'P0RoleIamManager',
        PolicyName: 'P0RoleIamManagerPolicy'
      });
      await iam.send(deleteRolePolicyCommand);
      console.log('Successfully deleted inline policy in account:', accountId);
    } catch (error) {
      if (error.name !== 'NoSuchEntityException') {
        throw error;
      }
      console.log('Policy did not exist in account:', accountId);
    }
    
    // Delete the role
    console.log('Deleting P0RoleIamManager role in account:', accountId);
    try {
      const deleteRoleCommand = new DeleteRoleCommand({
        RoleName: 'P0RoleIamManager'
      });
      await iam.send(deleteRoleCommand);
      console.log('Successfully deleted role in account:', accountId);
    } catch (error) {
      if (error.name !== 'NoSuchEntityException') {
        throw error;
      }
      console.log('Role did not exist in account:', accountId);
    }
    
    console.log('Successfully completed cleanup for account:', accountId);
    return { accountId, status: 'success' };
  } catch (error) {
    console.error('Error cleaning up account', accountId, ':', error);
    console.error('Error details:', JSON.stringify(error, null, 2));
    return { accountId, status: 'error', error: error.message };
  } finally {
    console.log('============================================');
  }
}

async function processAccount(accountId, googleAudienceId) {
  console.log('============================================');
  console.log('Starting to process account:', accountId);
  const sts = new STSClient({ region: 'us-east-1' });
  
  try {
    // Assume OrganizationAccountAccessRole in member account
    console.log('Assuming OrganizationAccountAccessRole in account:', accountId);
    const assumeRoleCommand = new AssumeRoleCommand({
      RoleArn: "arn:aws:iam::" + accountId + ":role/OrganizationAccountAccessRole",
      RoleSessionName: 'CreateMemberRole'
    });
    const assumeRole = await sts.send(assumeRoleCommand);
    console.log('Successfully assumed role in account:', accountId);
    
    // Create IAM client with temporary credentials
    const iam = new IAMClient({
      credentials: {
        accessKeyId: assumeRole.Credentials.AccessKeyId,
        secretAccessKey: assumeRole.Credentials.SecretAccessKey,
        sessionToken: assumeRole.Credentials.SessionToken
      },
      region: 'us-east-1'
    });
    
    // Create role in member account
    console.log('Creating P0RoleIamManager in account:', accountId);
    const createRoleCommand = new CreateRoleCommand({
      RoleName: 'P0RoleIamManager',
      AssumeRolePolicyDocument: JSON.stringify({
        Version: '2012-10-17',
        Statement: [{
          Effect: 'Allow',
          Principal: {
            Federated: 'accounts.google.com'
          },
          Action: 'sts:AssumeRoleWithWebIdentity',
          Condition: {
            StringEquals: {
              'accounts.google.com:aud': googleAudienceId
            }
          }
        }]
      })
    });
    
    try {
      await iam.send(createRoleCommand);
      console.log('Successfully created role in account:', accountId);
    } catch (error) {
      if (error.name === 'EntityAlreadyExistsException') {
        console.log('Role already exists in account:', accountId);
      } else {
        throw error;
      }
    }

    // Read and process policy file
    console.log('Reading policy file for account:', accountId);
    try {
      const policyPath = path.join(__dirname, 'p0_role_policy.json');
      const policyContent = fs.readFileSync(policyPath, 'utf8');
      const policy = policyContent.replace(/\$\{account_id\}/g, accountId);
      console.log('Processed policy content:', policy);
      
      console.log('Adding inline policy to P0RoleIamManager in account:', accountId);
      const putRolePolicyCommand = new PutRolePolicyCommand({
        RoleName: 'P0RoleIamManager',
        PolicyName: 'P0RoleIamManagerPolicy',
        PolicyDocument: policy
      });
      
      try {
        await iam.send(putRolePolicyCommand);
        console.log('Successfully attached policy to role in account:', accountId);
      } catch (policyError) {
        console.error('Error attaching policy in account', accountId, ':', policyError);
        throw policyError;
      }
    } catch (policyProcessError) {
      console.error("Error processing policy file for account", accountId, ":", policyProcessError);
      throw policyProcessError;
    }
    
    console.log('Successfully completed all operations for account:', accountId);
    return { accountId, status: 'success' };
  } catch (error) {
    console.error('Error processing account', accountId, ':', error);
    console.error('Error details:', JSON.stringify(error, null, 2));
    return { accountId, status: 'error', error: error.message };
  } finally {
    console.log('============================================');
  }
}

exports.handler = async (event) => {
  try {
    // Check if this is a cleanup operation
    const isCleanup = event && event.cleanup === true;
    console.log(isCleanup ? 'Running cleanup operation' : 'Running role creation operation');

    // Determine which accounts to process
    let accountsToProcess = [];
    const specifiedAccounts = JSON.parse(process.env.MEMBER_ACCOUNTS || '[]');
    
    if (specifiedAccounts.length === 0) {
      console.log('No specific accounts provided. Discovering all organization accounts...');
      accountsToProcess = await getOrganizationAccounts();
    } else {
      console.log('Processing specified accounts:', specifiedAccounts);
      accountsToProcess = specifiedAccounts;
    }
    
    // Process accounts in parallel with a concurrency limit
    const concurrencyLimit = 3;
    const results = [];
    
    for (let i = 0; i < accountsToProcess.length; i += concurrencyLimit) {
      const batch = accountsToProcess.slice(i, i + concurrencyLimit);
      const batchResults = await Promise.all(
        batch.map(accountId => 
          isCleanup ? 
          cleanupAccount(accountId) : 
          processAccount(accountId, process.env.GOOGLE_AUDIENCE_ID)
        )
      );
      results.push(...batchResults);
    }
    
    const successful = results.filter(r => r.status === 'success').length;
    const failed = results.filter(r => r.status === 'error').length;
    
    return {
      statusCode: 200,
      body: JSON.stringify({
        message: isCleanup ? 'Role cleanup process completed' : 'Role creation process completed',
        totalAccounts: results.length,
        successfulAccounts: successful,
        failedAccounts: failed,
        details: results
      })
    };
  } catch (error) {
    console.error('Lambda execution error:', error);
    throw error;
  }
};
EOF
}

# Create Lambda function package
data "archive_file" "lambda_function" {
  type        = "zip"
  output_path = "lambda_function.zip"
  source_dir  = "lambda"
  
  depends_on = [
    local_file.lambda_source,
    local_file.policy_template
  ]
}

# Create Lambda function
resource "aws_lambda_function" "create_member_roles" {
  provider         = aws.root
  filename         = data.archive_file.lambda_function.output_path
  function_name    = "create-member-account-roles"
  role            = aws_iam_role.lambda_role.arn
  handler         = "index.handler"
  runtime         = "nodejs18.x"
  timeout         = 300
  memory_size     = 256
  
  layers = [aws_lambda_layer_version.dependencies.arn]

  environment {
    variables = {
      MEMBER_ACCOUNTS    = jsonencode(var.member_accounts)
      GOOGLE_AUDIENCE_ID = var.google_audience_id
      ROOT_ACCOUNT_ID    = var.root_account_id
    }
  }
}

# Account discovery process
resource "null_resource" "discover" {
  depends_on = [aws_lambda_function.create_member_roles]

  triggers = {
    always_run = timestamp()
  }

  provisioner "local-exec" {
    command = <<-EOF
      aws lambda invoke \
        --function-name ${aws_lambda_function.create_member_roles.function_name} \
        --region us-east-1 \
        --cli-binary-format raw-in-base64-out \
        response.json && \
      echo '{"accounts":["${var.root_account_id}"]}' > ${local_file.account_tracker.filename} && \
      cat response.json | jq -r '.body | fromjson | .details[] | select(.status == "success") | .accountId' | while read account; do
        content=$(cat ${local_file.account_tracker.filename})
        echo "$content" | jq --arg acc "$account" '.accounts += [$acc]' > ${local_file.account_tracker.filename}
      done
    EOF
  }
}



# Read account list file
data "local_file" "account_list" {
  depends_on = [null_resource.discover]
  filename = local_file.account_tracker.filename
}

# Read existing accounts file if it exists, otherwise use root account
locals {
  existing_accounts = fileexists("${path.module}/discovered_accounts.json") ? jsondecode(file("${path.module}/discovered_accounts.json")).accounts : [var.root_account_id]
}

# P0 Configuration for all accounts
resource "p0_aws_iam_write_staged" "aws_staged" {
  for_each = toset(local.existing_accounts)
  id       = each.key
  
  depends_on = [null_resource.discover]
}

resource "p0_aws_iam_write" "aws_install" {
  for_each = toset(local.existing_accounts)
  
  depends_on = [p0_aws_iam_write_staged.aws_staged]
  id        = p0_aws_iam_write_staged.aws_staged[each.key].id
  
  login = {
    type   = "idc"
    parent = var.root_account_id
  }
}

# Pre-destroy cleanup
resource "null_resource" "pre_destroy_cleanup" {
  depends_on = [aws_lambda_function.create_member_roles]

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOF
      for i in {1..3}; do
        echo "Attempting cleanup (attempt $i)..."
        aws lambda invoke \
          --function-name ${self.triggers.function_name} \
          --payload '{"cleanup":true}' \
          --cli-binary-format raw-in-base64-out \
          --region us-east-1 \
          cleanup_response.json && break || sleep 10
      done
    EOF

    working_dir = path.module
  }

  triggers = {
    function_name = aws_lambda_function.create_member_roles.function_name
  }
}

# Outputs
output "root_role_arn" {
  value       = aws_iam_role.root_role.arn
  description = "ARN of the P0RoleIamManager role in the root account"
}

output "lambda_function_arn" {
  value       = aws_lambda_function.create_member_roles.arn
  description = "ARN of the Lambda function that creates roles in member accounts"
}

output "discovered_accounts" {
  value = local.existing_accounts
  description = "All discovered AWS accounts"
}

output "p0_staged_ids" {
  value = {
    for account_id in local.existing_accounts : 
    account_id => p0_aws_iam_write_staged.aws_staged[account_id].id
  }
  description = "P0 staged configuration IDs for all accounts"
}