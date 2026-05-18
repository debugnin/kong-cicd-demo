terraform {
  required_version = ">= 1.6.0"

  required_providers {
    konnect = {
      source  = "kong/konnect"
      version = "~> 3.0"
    }
  }
}
