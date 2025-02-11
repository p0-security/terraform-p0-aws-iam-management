terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    p0 = {
      source  = "p0-security/p0"
      version = "~> 0.14.0"
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

provider "p0" {
  org  = "tenant-name" #typically its in the url as https://p0.app/o/<tenant-name>
  host = "https://api.p0.app"
}
