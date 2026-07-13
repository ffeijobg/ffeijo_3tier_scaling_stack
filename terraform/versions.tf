# terraform/versions.tf
# The tehcyx/kind provider is the most stable provider for KinD lifecycle management.
# Pin to a minor version to avoid breaking changes in provider API.
 
terraform {
  required_version = ">= 1.8"
 
  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = "~> 0.6.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }
}
