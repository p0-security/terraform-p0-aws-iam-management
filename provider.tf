terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Root account provider - uses TerraformExecutionRole
provider "aws" {
  alias  = "root"
  region = "us-east-1"
  
  assume_role {
    role_arn = "arn:aws:iam::${var.root_account_id}:role/TerraformExecutionRole"
  }
}