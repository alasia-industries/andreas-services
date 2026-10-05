# envs/shared/backend.tf
# Remote state for shared platform infrastructure

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket  = "andreas-services-terraform-state"
    key     = "shared/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
    # S3-native state locking (Terraform >= 1.10). This state had no lock at
    # all: no DynamoDB table was ever configured.
    use_lockfile = true
  }
}
