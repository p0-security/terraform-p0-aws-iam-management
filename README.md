# AWS IAM Role Manager

This Terraform project sets up IAM roles to use with P0 Security (via Google federation) across root and member accounts of an AWS Organization.

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

2. AWS Organization with:
   - Root (management) account
   - One or more member accounts
   - OrganizationAccountAccessRole available in member accounts

3. AWS Identity Center (formerly SSO) configured with Google federation

## IAM Roles Overview

### Prerequisites Roles
1. **TerraformExecutionRole** (in root account)
   - Used by: Terraform
   - Purpose: Creates initial resources and Lambda function
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
├── provider.tf                       # AWS provider configuration
├── terraform.tfvars                  # Your variable values
├── iam/
│   ├── terraform-execution-role.json       # Trust policy for TerraformExecutionRole
│   └── terraform-execution-role-policy.json # Permission policy for TerraformExecutionRole
├── policies/
│   └── p0_role_policy.json          # Policy template
```

## Steps

1. Edit the file terraform.tfvars in the root folder as follows:
    1. Add your root account as a string value
    2. Add your children/member accounts in an array of comma separated strings
    3. Add the P0 Security Google Audience ID

2. In the root folder, run the following commands:
    ```bash
    terraform init
    terraform plan
    terraform apply
    ```

## Tasks Performed

1. In the Root/Management Account:
   - Created by TerraformExecutionRole:
     - P0RoleIamManager role with Google federation
     - P0RoleIamManagerPolicy (inline policy) attached to P0RoleIamManager
     - role-creation-lambda-role for the Lambda function
     - role-creation-policy (inline policy) for Lambda role
     - Lambda function called create-member-account-roles

2. In Each Child Account:
   - Created by Lambda (which assumes OrganizationAccountAccessRole):
     - P0RoleIamManager role with same Google federation
     - P0RoleIamManagerPolicy (inline policy) attached to P0RoleIamManager

## Workflow

1. Initial Setup:
   ```
   Your AWS Identity → TerraformExecutionRole
   ```
   - Terraform uses your provided TerraformExecutionRole to create resources in root account

2. Lambda Creation:
   - Terraform creates a zip package containing:
     - Lambda function code (index.js)
     - Policy template (p0_role_policy.json)
   - Package is uploaded to AWS Lambda

3. Member Account Role Creation:
   ```
   Lambda → OrganizationAccountAccessRole → Create P0RoleIamManager
   ```
   - Lambda function iterates through member accounts
   - For each account:
     - Assumes the OrganizationAccountAccessRole
     - Creates P0RoleIamManager with Google federation
     - Reads policy template from package
     - Replaces ${account_id} placeholder with current account ID
     - Attaches policy to the role

4. Final Trust Chain:
   ```
   Google Federation (P0 Security) → P0RoleIamManager (in any account)
   ```
   - End users can assume P0RoleIamManager in any account through P0 Security