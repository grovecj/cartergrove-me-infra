# beach.cartergrove.me: a static page of live cams from Schooners (Panama City
# Beach), the start of a dashboard. The page lives in its own private repo
# (var.repo) and is served as-is, with no build step.

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
  project = "beach"

  # Every resource in this project is named "<project>-..." and, where the
  # resource type supports tags, tagged with this. (None of the ones below do.)
  tags = ["project:${local.project}"]

  region   = data.terraform_remote_state.shared.outputs.region
  domain   = data.terraform_remote_state.shared.outputs.domain
  hostname = "${local.project}.${local.domain}"

  # App Platform names regions by city ("nyc"), while Droplets, Spaces, VPCs
  # etc. name the datacenter ("nyc1"). Strip the trailing digits.
  app_region = regex("^[a-z]+", local.region)
}

# The DigitalOcean Project that groups this project's resources in the
# control panel. `resources` takes URNs ("do:app:<id>", ...).
resource "digitalocean_project" "beach" {
  name        = local.project
  description = "beach.cartergrove.me: live cams from Schooners, Panama City Beach."
  purpose     = "Website or blog"
  environment = "Production"
  resources = [
    digitalocean_app.site.urn,
  ]
}

# --- App ---------------------------------------------------------------------

resource "digitalocean_app" "site" {
  spec {
    name   = "${local.project}-site"
    region = local.app_region

    # The custom domain. App Platform issues and renews the TLS certificate
    # itself once the DNS record below points at the app.
    domain {
      name = local.hostname
      type = "PRIMARY"
    }

    # The repo root holds index.html, so there's nothing to build: "/" serves
    # it as-is. Left unset, App Platform would look for a build output folder
    # (dist/, public/, ...) that doesn't exist. Pushing to the branch redeploys.
    static_site {
      name       = "web"
      output_dir = "/"

      github {
        repo           = var.repo
        branch         = var.branch
        deploy_on_push = true
      }
    }
  }
}

# beach.cartergrove.me -> the app's own *.ondigitalocean.app hostname.
# default_ingress is a URL ("https://beach-site-xxxxx.ondigitalocean.app"); a
# CNAME needs just the hostname, as an FQDN with a trailing dot.
resource "digitalocean_record" "site" {
  domain = local.domain
  type   = "CNAME"
  name   = local.project
  value  = "${trimprefix(digitalocean_app.site.default_ingress, "https://")}."
  ttl    = 3600
}
