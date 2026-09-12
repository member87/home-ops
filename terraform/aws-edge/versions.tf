terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  # State lives in the Terrakube workspace "aws-edge" (organization homeops);
  # runs execute remotely. Never commit *.tfstate (gitignored).
}
