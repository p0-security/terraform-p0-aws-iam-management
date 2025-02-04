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
  name = "role-creation-lambda-role"

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
  role = aws_iam_role.lambda_role.id
  name = "role-creation-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sts:AssumeRole",
          "organizations:ListAccounts",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

# Create a directory for the Lambda package
resource "local_file" "lambda_source" {
  filename = "lambda/index.js"
  content = <<EOF
const { STSClient, AssumeRoleCommand } = require('@aws-sdk/client-sts');
const { IAMClient, CreateRoleCommand, PutRolePolicyCommand } = require('@aws-sdk/client-iam');
const fs = require('fs');
const path = require('path');

exports.handler = async (event) => {
  try {
    const memberAccounts = JSON.parse(process.env.MEMBER_ACCOUNTS);
    console.log('Processing member accounts:', memberAccounts);
    
    for (const accountId of memberAccounts) {
      console.log('Processing account:', accountId);
      const sts = new STSClient({ region: 'us-east-1' });
      
      try {
        // Assume OrganizationAccountAccessRole in member account
        console.log('Assuming OrganizationAccountAccessRole in account:', accountId);
        const assumeRoleCommand = new AssumeRoleCommand({
          RoleArn: "arn:aws:iam::" + accountId + ":role/OrganizationAccountAccessRole",
          RoleSessionName: 'CreateMemberRole'
        });
        const assumeRole = await sts.send(assumeRoleCommand);
        
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
                  'accounts.google.com:aud': process.env.GOOGLE_AUDIENCE_ID
                }
              }
            }]
          })
        });
        await iam.send(createRoleCommand);

        // Read and process policy file
        const policyPath = path.join(__dirname, 'policies', 'p0_role_policy.json');
        console.log('Reading policy from:', policyPath);
        const policyContent = fs.readFileSync(policyPath, 'utf8');
        const policy = policyContent.replace(/\$\{account_id\}/g, accountId);
        
        // Add inline policy to the role
        console.log('Adding inline policy to P0RoleIamManager in account:', accountId);
        const putRolePolicyCommand = new PutRolePolicyCommand({
          RoleName: 'P0RoleIamManager',
          PolicyName: 'P0RoleIamManagerPolicy',
          PolicyDocument: policy
        });
        await iam.send(putRolePolicyCommand);
        
        console.log('Successfully processed account:', accountId);
      } catch (accountError) {
        console.error('Error processing account', accountId, ':', accountError);
        throw accountError;
      }
    }
    
    return {
      statusCode: 200,
      body: 'Roles created successfully'
    };
  } catch (error) {
    console.error('Lambda execution error:', error);
    throw error;
  }
};
EOF
}

# Copy the policy file to the Lambda package directory
resource "local_file" "policy_copy" {
  filename = "lambda/policies/p0_role_policy.json"
  source   = "${path.module}/policies/p0_role_policy.json"
}

# Create the final Lambda package with both files
data "archive_file" "lambda_zip" {
  type        = "zip"
  output_path = "create_roles.zip"
  source_dir  = "lambda"
  
  depends_on = [
    local_file.lambda_source,
    local_file.policy_copy
  ]
}

# Create Lambda function
resource "aws_lambda_function" "create_member_roles" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "create-member-account-roles"
  role            = aws_iam_role.lambda_role.arn
  handler         = "index.handler"
  runtime         = "nodejs18.x"
  timeout         = 300

  environment {
    variables = {
      MEMBER_ACCOUNTS    = jsonencode(var.member_accounts)
      GOOGLE_AUDIENCE_ID = var.google_audience_id
    }
  }
}

# Trigger Lambda function
resource "null_resource" "trigger_lambda" {
  depends_on = [aws_lambda_function.create_member_roles]

  provisioner "local-exec" {
    command = <<EOF
aws lambda invoke \
  --function-name ${aws_lambda_function.create_member_roles.function_name} \
  --region us-east-1 \
  --log-type Tail \
  --query 'LogResult' \
  --output text response.json | base64 -d
EOF
  }
}