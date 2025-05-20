terraform {
  backend "s3" {
    bucket = "nhutle-s3-bucket"
    key    = "devops-final-exam/terraform.tfstate"
    region = "us-east-1"
  }
} 