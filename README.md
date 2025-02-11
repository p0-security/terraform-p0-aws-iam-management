# AWS IAM and P0 Security Integration Manager

This Terraform project sets up IAM roles across AWS Organizations and configures P0 Security integration for both root and member accounts automatically.

## Prerequisites

1. **TerraformExecutionRole**
    If you need to create this role:
    1. Modify the file iam/terraform-execution-role.json and add your AWS Principal (Role) that will be used to assume the terraform role.
    2. Execute the following steps in the root folder:

        ```bash
        aws iam create-role \
            --role-name TerraformExecutionRole \
            --assume-role-policy-document file://iam/terraform-execution-role.json

        aws iam put-role-policy \
            --role-name TerraformExecutionRole \
            --policy-name TerraformExecutionPolicy \
            --policy-document file://iam/terraform-execution-role-policy.json
        ```

2. **AWS Organization Requirements**:
   - Root (management) account
   - One or more member accounts
   - OrganizationAccountAccessRole available in member accounts
   - AWS Organizations API access enabled

3. **P0 Security Requirements**:
   - P0 API Token (create at p0.app)
   - P0 Organization name

4. **Local Environment**:
   - AWS CLI configured
   - jq installed (for JSON processing)
   - Terraform installed

## Environment Variables

```bash
P0_API_TOKEN
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
AWS_SESSION_TOKEN
```

## IAM Roles Overview

### Prerequisites Roles
1. **TerraformExecutionRole** (in root account)
   - Used by: Terraform
   - Purpose: Creates initial resources, Lambda function, and P0 configurations
   - Key Permissions:
     - IAM role and policy management
     - Lambda function management
     - Organizations API access

2. **OrganizationAccountAccessRole** (in member accounts)
   - Used by: Lambda function
   - Purpose: Allows cross-account access from management account
   - Must exist before running this project

### Created Roles

1. **P0RoleIamManager** (created in all accounts)
   - Created in: Root and all member accounts
   - Purpose: Managed role for Google federation
   - Trust Relationship: Google federation
   - Inline Policy: P0RoleIamManagerPolicy

2. **role-creation-lambda-role** (in root account only)
   - Created in: Root account
   - Purpose: Execution role for Lambda function
   - Used by: create-member-account-roles Lambda function
   - Has: role-creation-policy (inline policy)

## Project Structure

```
project_root/
├── main.tf                           # Main Terraform config
├── variables.tf                      # Variable definitions
├── provider.tf                       # AWS and P0 provider configuration
├── terraform.tfvars                  # Your variable values
├── iam/
│   ├── terraform-execution-role.json       # Trust policy for TerraformExecutionRole
│   └── terraform-execution-role-policy.json # Permission policy for TerraformExecutionRole
├── policies/
    └── p0_role_policy.json          # Policy template for P0 role
```

## Configuration

1. Create `terraform.tfvars`:
```hcl
root_account_id = "123456789012"      # Your root AWS account ID
member_accounts = []                   # Leave empty for auto-discovery
google_audience_id = "your_audience_id"  # From P0 Security console
```

2. Configure `provider.tf`:
```hcl
provider "p0" {
  org  = "your-org-name"     # Your P0 organization name
  host = "https://api.p0.app" 
}
```

## Steps

1. Initialize and plan:
```bash
terraform init
terraform plan -target=aws_iam_role.lambda_role -target=aws_iam_role_policy.lambda_role_policy -target=aws_lambda_function.create_member_roles -target=null_resource.discover
```

2. Apply Lambda and discovery resources:
```bash
terraform apply -target=aws_iam_role.lambda_role -target=aws_iam_role_policy.lambda_role_policy -target=aws_lambda_function.create_member_roles -target=null_resource.discover
```

3. Apply P0 configuration:
```bash
terraform apply
```

## Tasks Performed

1. In the Root Account:
   - Creates P0RoleIamManager with Google federation for P0 Security
   - Sets up Lambda function for account discovery
   - Configures P0 Security integration

2. In Member Accounts (via Lambda):
   - Creates P0RoleIamManager with Google federation for P0 Security
   - Applies consistent IAM policies

3. In P0 Security:
   - Configures AWS IAM integrations for all accounts
   - Sets up proper parent-child relationships for Identity Center


## Workflow

1. Initial Setup:
   ```
   Your AWS Identity → TerraformExecutionRole → Create Initial Resources
   ```

2. Account Discovery:
   ```
   Lambda → AWS Organizations API → Discover Member Accounts
   ```

3. Role Creation:
   ```
   Lambda → OrganizationAccountAccessRole → Create P0RoleIamManager in Each Account
   ```

4. P0 Configuration:
   ```
   Terraform → P0 API → Configure AWS Integration for All Accounts
   ```

5. Final Trust Chain:
   ```
   Google Federation (P0 Security) → P0RoleIamManager (in any account)
   ```

## Notes

- The Lambda function will automatically discover all active accounts in your organization
- P0 configuration will be applied to all discovered accounts
- The root account is always configured as the parent for all member accounts
- Role propagation may take a few minutes after creation
