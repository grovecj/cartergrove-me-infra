# games.cartergrove.me: a single App Platform app hosting every game at its own
# path (/match3, ...). Resources are added in grovecj/cartergrove-me-infra#3.

# Read the outputs of the shared/ root module from its state file. This is
# read-only: nothing here can change shared resources. The config must match
# shared/'s backend block (same bucket and endpoint, shared/'s key).
data "terraform_remote_state" "shared" {
  backend = "s3"

  config = {
    bucket    = "cartergrove-me-tfstate"
    key       = "shared/terraform.tfstate"
    endpoints = { s3 = "https://nyc3.digitaloceanspaces.com" }

    region                      = "us-east-1"
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_s3_checksum            = true
  }
}

locals {
  project = "games"

  # Every resource in this project is named "<project>-..." and tagged with this.
  tags = ["project:${local.project}"]

  region = data.terraform_remote_state.shared.outputs.region
  domain = data.terraform_remote_state.shared.outputs.domain
}
