# games.cartergrove.me: a single App Platform app hosting every game at its own
# path (/match3, ...), plus a Spaces bucket + CDN for downloadable builds.
#
# Why one app for all games: App Platform attaches a custom domain to exactly
# one app and routes paths only to that app's own components. So each game is a
# *component* of the hub app (declared in var.games), not an app of its own.

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

  # Every resource in this project is named "<project>-..." and, where the
  # resource type supports tags, tagged with this. (None of the ones below do.)
  tags = ["project:${local.project}"]

  region   = data.terraform_remote_state.shared.outputs.region
  domain   = data.terraform_remote_state.shared.outputs.domain
  hostname = "${local.project}.${local.domain}"

  # App Platform names regions by city ("nyc"), while Droplets, Spaces, VPCs
  # etc. name the datacenter ("nyc3"). Strip the trailing digits.
  app_region = regex("^[a-z]+", local.region)
}

# The DigitalOcean Project that groups this project's resources in the
# control panel. `resources` takes URNs ("do:app:<id>", ...).
resource "digitalocean_project" "games" {
  name        = local.project
  description = "games.cartergrove.me: browser games and their downloads."
  purpose     = "Website or blog"
  environment = "Production"
  resources = [
    digitalocean_app.hub.urn,
    digitalocean_spaces_bucket.downloads.urn,
  ]
}

# --- Hub app -----------------------------------------------------------------

resource "digitalocean_app" "hub" {
  spec {
    name   = "${local.project}-hub"
    region = local.app_region

    # The custom domain. App Platform issues and renews the TLS certificate
    # itself once the DNS record below points at the app. (Setting `zone` here
    # would have DO create that record for us; we create it ourselves so it's
    # visible in, and owned by, this config.)
    domain {
      name = local.hostname
      type = "PRIMARY"
    }

    # Landing page at "/". It's a plain HTML file kept in this repo
    # (projects/games/hub/), so there's nothing to build. Pushing a change to
    # it on main redeploys it. `output_dir` is relative to `source_dir`: "/"
    # serves the directory as-is. Left unset, App Platform would look for a
    # build output folder (dist/, public/, ...) that doesn't exist here.
    static_site {
      name       = "hub"
      source_dir = "projects/games/hub"
      output_dir = "/"

      github {
        repo           = "grovecj/cartergrove-me-infra"
        branch         = "main"
        deploy_on_push = true
      }
    }

    # One static site per game. A `dynamic` block repeats its `content` once
    # per element of `for_each`; inside it, `static_site.key` is the map key
    # ("match3") and `static_site.value` the object ({ repo, branch }).
    # Each game's branch holds a ready-made build (index.html at its root), so
    # again there's no build command and the branch root is served as-is.
    dynamic "static_site" {
      for_each = var.games
      content {
        name       = static_site.key
        output_dir = "/"

        github {
          repo           = static_site.value.repo
          branch         = static_site.value.branch
          deploy_on_push = true
        }
      }
    }

    # Routing: which component answers which path. App Platform sends each
    # request to the rule with the longest matching prefix, so "/match3/..."
    # goes to the match3 component and everything else falls through to "/".
    # The prefix is stripped before the request reaches the component:
    # "/match3/Build/x.wasm" is served as "/Build/x.wasm" from the match3 site.
    ingress {
      dynamic "rule" {
        for_each = var.games
        content {
          component {
            name = rule.key
          }
          match {
            path {
              prefix = "/${rule.key}"
            }
          }
        }
      }

      rule {
        component {
          name = "hub"
        }
        match {
          path {
            prefix = "/"
          }
        }
      }
    }
  }
}

# games.cartergrove.me -> the app's own *.ondigitalocean.app hostname.
# default_ingress is a URL ("https://games-hub-xxxxx.ondigitalocean.app"); a
# CNAME needs just the hostname, as an FQDN with a trailing dot.
resource "digitalocean_record" "hub" {
  domain = local.domain
  type   = "CNAME"
  name   = local.project
  value  = "${trimprefix(digitalocean_app.hub.default_ingress, "https://")}."
  ttl    = 3600
}

# --- Downloads ---------------------------------------------------------------

# Downloadable builds (e.g. match3/Match3-Windows-latest.zip), one prefix per
# game. The bucket is private, so nobody can list its contents; CI uploads
# each file with a public-read ACL so the file itself can be downloaded.
# Spaces bucket names are unique per region across all DO customers.
resource "digitalocean_spaces_bucket" "downloads" {
  name   = "${local.project}-downloads"
  region = local.region
  acl    = "private"
}

# A CDN in front of the bucket: files are cached at edge locations near the
# player instead of always coming from NYC. `ttl` is how long (seconds) the
# edge keeps a copy before checking the bucket again, so after uploading a new
# "latest" zip either wait that long or purge the CDN cache.
resource "digitalocean_cdn" "downloads" {
  origin = digitalocean_spaces_bucket.downloads.bucket_domain_name
  ttl    = 3600
}
