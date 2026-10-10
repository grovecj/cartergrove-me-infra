# games.cartergrove.me: a single App Platform app hosting every game at its own
# path (/match3, ...), plus a Spaces bucket + CDN for downloadable builds.
# Games with a backend also get an API service at /<key>/api and a database on
# the shared Postgres cluster.
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

# The accounts service's outputs, for the issuer whose tokens game APIs accept.
# Same bucket, accounts' key. Only the state has to exist, so this works as
# long as projects/accounts has been applied once. It's only read when some
# game has an API (`count` of 1 or 0), so a hub without APIs doesn't depend on
# accounts at all.
data "terraform_remote_state" "accounts" {
  count   = length(local.apis) > 0 ? 1 : 0
  backend = "s3"

  config = {
    bucket    = "cartergrove-me-tfstate"
    key       = "projects/accounts/terraform.tfstate"
    endpoints = { s3 = "https://nyc3.digitaloceanspaces.com" }

    region                      = "us-east-1"
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_s3_checksum            = true
  }
}

# The monitoring/ root module's outputs: where game APIs push their telemetry
# (Grafana Cloud's OTLP gateway) and the credentials to do it with. Like
# accounts' state above, it's only read when some game has an API, and
# monitoring/ must have been applied once.
data "terraform_remote_state" "monitoring" {
  count   = length(local.apis) > 0 ? 1 : 0
  backend = "s3"

  config = {
    bucket    = "cartergrove-me-tfstate"
    key       = "monitoring/terraform.tfstate"
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
  postgres = data.terraform_remote_state.shared.outputs.postgres
  hostname = "${local.project}.${local.domain}"

  # The games that declare an api, as { key => api }. A `for` expression with
  # an `if` filters a map; this drives the API components and their databases.
  apis = { for key, game in var.games : key => game.api if game.api != null }

  # The sign-in issuer the APIs accept, or null when there are none. With
  # `count`, the data source is a list; `[*]` makes a list of its outputs and
  # `one()` turns a one- or zero-element list into its element or null.
  issuer = one(data.terraform_remote_state.accounts[*].outputs.issuer)

  # Where the APIs push telemetry, and the Authorization header value to send
  # with it. Null when there are no APIs. The header value holds a token, and
  # it's a sensitive output in monitoring/, but that marking is lost on the
  # way through terraform_remote_state: here it's a plain string that a plan
  # would print. sensitive() marks it again, so anything built from this
  # local shows as "(sensitive value)". Always use the local, never the data
  # source's attribute directly.
  otlp_endpoint      = one(data.terraform_remote_state.monitoring[*].outputs.otlp_endpoint)
  otlp_authorization = sensitive(one(data.terraform_remote_state.monitoring[*].outputs.otlp_authorization))

  # App Platform names regions by city ("nyc"), while Droplets, Spaces, VPCs
  # etc. name the datacenter ("nyc1"). Strip the trailing digits.
  app_region = regex("^[a-z]+", local.region)

  # The downloads bucket stays in nyc3, where it was created, even though the
  # shared region is now nyc1: a bucket's region can't change in place, so
  # following the shared region would replace it and delete its files.
  spaces_region = "nyc3"
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

# --- Game API databases -------------------------------------------------------

# One database and user per game API, named after the game ("match3"), on the
# shared cluster. `for_each` on a module makes one instance per map entry,
# addressed as module.db["match3"]. After the first apply, grant the user
# CREATE on the public schema, or Flyway's migrations fail (see the README).
module "db" {
  source   = "../../modules/project-database"
  for_each = local.apis

  name    = each.key
  cluster = local.postgres
}

# --- Hub app -----------------------------------------------------------------

resource "digitalocean_app" "hub" {
  spec {
    name   = "${local.project}-hub"
    region = local.app_region

    # Enhanced threat control stays off. It answers requests with a
    # JavaScript challenge page ("Just a moment..."), across the whole app.
    # Browsers can pass that, but a game API's other clients can't (Unity's
    # UnityWebRequest in the Windows build, curl), so they'd only ever get a
    # 403. The APIs rate-limit per player and per IP themselves. Declared
    # explicitly so a control-panel change shows up in the next plan.
    enhanced_threat_control_enabled = false

    # The custom domain. App Platform issues and renews the TLS certificate
    # itself once the DNS record below points at the app. (Setting `zone` here
    # would have DO create that record for us; we create it ourselves so it's
    # visible in, and owned by, this config.)
    domain {
      name = local.hostname
      type = "PRIMARY"
    }

    # Attach the app to the shared VPC when any game has an API, so the APIs
    # reach Postgres on `private_host` over the private network. The database
    # firewall (in shared/) trusts the whole VPC range, so nothing is opened
    # to the internet. A `dynamic` block over a one- or zero-element list is
    # how Terraform writes "this block only if ...".
    dynamic "vpc" {
      for_each = length(local.apis) > 0 ? [data.terraform_remote_state.shared.outputs.vpc_id] : []
      content {
        id = vpc.value
      }
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

    # One service per game API, "<key>-api", built from its repo's Dockerfile.
    # Only games in local.apis get one. `service.key` is the game key
    # ("match3"), `service.value` its api object.
    dynamic "service" {
      for_each = local.apis
      content {
        name               = "${service.key}-api"
        instance_size_slug = service.value.instance_size
        instance_count     = 1
        # Spring Boot's port (its PORT default in the API).
        http_port = 8081

        dockerfile_path = "Dockerfile"
        github {
          repo           = service.value.repo
          branch         = service.value.branch
          deploy_on_push = true
        }

        # A new deployment only takes traffic once this returns 200, so a
        # build that can't start (bad config, failed migration) never
        # replaces a working one. The health check talks to the container
        # directly, not through the ingress, so the path includes the API's
        # context path (see the routing rule below).
        health_check {
          http_path             = "/${service.key}/api/actuator/health"
          initial_delay_seconds = 30
          period_seconds        = 10
        }

        # SECRET values are encrypted by App Platform and hidden in its
        # control panel. The provider marks every env `value` sensitive, so
        # plans print none of them.
        env {
          key   = "SPRING_DATASOURCE_URL"
          value = "jdbc:postgresql://${local.postgres.private_host}:${local.postgres.port}/${module.db[service.key].database}?sslmode=require"
          scope = "RUN_TIME"
          type  = "GENERAL"
        }
        env {
          key   = "SPRING_DATASOURCE_USERNAME"
          value = module.db[service.key].user
          scope = "RUN_TIME"
          type  = "GENERAL"
        }
        env {
          key   = "SPRING_DATASOURCE_PASSWORD"
          value = module.db[service.key].password
          scope = "RUN_TIME"
          type  = "SECRET"
        }
        # Sign-in: the API accepts tokens from the accounts service whose
        # `aud` names the game. It checks them against the issuer's public
        # keys (JWKS), so it needs no auth secrets.
        env {
          key   = "AUTH_ISSUER"
          value = local.issuer
          scope = "RUN_TIME"
          type  = "GENERAL"
        }
        env {
          key   = "AUTH_AUDIENCE"
          value = service.key
          scope = "RUN_TIME"
          type  = "GENERAL"
        }
        # Monitoring: the API pushes its metrics to this OTLP endpoint,
        # sending the second value as its Authorization header. Every game
        # API gets the same pair: the token inside can only write telemetry
        # (see monitoring/). With these unset an API sends nothing. The
        # third labels everything it sends, so a run on someone's laptop
        # ("local", the API's default) never mixes with this one's data.
        env {
          key   = "GRAFANA_OTLP_ENDPOINT"
          value = local.otlp_endpoint
          scope = "RUN_TIME"
          type  = "GENERAL"
        }
        env {
          key   = "GRAFANA_OTLP_AUTHORIZATION"
          value = local.otlp_authorization
          scope = "RUN_TIME"
          type  = "SECRET"
        }
        env {
          key   = "DEPLOYMENT_ENVIRONMENT"
          value = "production"
          scope = "RUN_TIME"
          type  = "GENERAL"
        }
      }
    }

    # Routing: which component answers which path. App Platform sends each
    # request to the rule with the longest matching prefix, so "/match3/..."
    # goes to the match3 component and everything else falls through to "/".
    # The prefix is stripped before the request reaches the component:
    # "/match3/Build/x.wasm" is served as "/Build/x.wasm" from the match3 site.
    ingress {
      # "/match3/api" is longer than "/match3", so API requests go to the API.
      # Unlike the static sites, these rules keep the prefix
      # (preserve_path_prefix): the API's context path is "/<key>/api", the
      # same locally as in production, so its own links and the health check
      # path are the same everywhere.
      dynamic "rule" {
        for_each = local.apis
        content {
          component {
            name                 = "${rule.key}-api"
            preserve_path_prefix = true
          }
          match {
            path {
              prefix = "/${rule.key}/api"
            }
          }
        }
      }

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
  region = local.spaces_region
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
