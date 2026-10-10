terraform {
  # Pin Terraform itself: any 1.x from 1.14 up. The exact provider build is
  # pinned separately by the committed .terraform.lock.hcl.
  required_version = "~> 1.14"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.102"
    }
    # Only for uptime checks (Grafana Cloud Synthetic Monitoring). Same
    # version as monitoring/, which installs it.
    grafana = {
      source  = "grafana/grafana"
      version = "~> 4.49"
    }
    # Generates the JWT signing key (tls_private_key). It runs entirely inside
    # Terraform: no API, no credentials.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.1"
    }
  }

  # State lives in a DigitalOcean Spaces bucket, which speaks the S3 API, so we
  # use Terraform's built-in "s3" backend pointed at the Spaces endpoint.
  # Backend blocks can't use variables, so these values are literals, repeated
  # in every root module; only `key` differs. See bootstrap/README.md.
  backend "s3" {
    bucket = "cartergrove-me-tfstate"
    key    = "projects/accounts/terraform.tfstate"

    endpoints = { s3 = "https://nyc3.digitaloceanspaces.com" }

    # The S3 backend expects an AWS region; Spaces ignores it, so any valid
    # value works. The skip_* flags turn off AWS-only checks that Spaces fails.
    region                      = "us-east-1"
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_s3_checksum            = true
  }
}
