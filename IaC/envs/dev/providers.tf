terraform{
    backend "s3" {}
    required_providers {
      aws = {
        source = "hashicorp/aws"
        version = "~> 5.0"
      }
    }
    required_version = ">= 1.2"
}
provider "aws" {
    region = "eu-central-1"
}