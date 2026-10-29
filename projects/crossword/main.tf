# crossword.cartergrove.me: build crossword puzzles with AI help and publish
# them for anyone to play (grovecj/crossword). One App Platform app from one
# repo: the Spring Boot backend as a service at /api, and the React frontend
# as a static site at /, so the browser talks to one origin and needs no CORS.
# Plus a database on the shared Postgres cluster (no cluster of its own).

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

# The monitoring/ root module's outputs: where the backend pushes its
# telemetry (Grafana Cloud's OTLP gateway) and the credentials to do it with.
# Same bucket, monitoring's key.
data "terraform_remote_state" "monitoring" {
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

# The accounts service's outputs, for the issuer users sign in with and whose
# tokens the backend accepts. Same bucket, accounts' key; projects/accounts
# must have been applied once.
data "terraform_remote_state" "accounts" {
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

locals {
  project = "crossword"

  # Every resource in this project is named "<project>-..." and, where the
  # resource type supports tags, tagged with this. (None of the ones below do.)
  tags = ["project:${local.project}"]

  region   = data.terraform_remote_state.shared.outputs.region
  domain   = data.terraform_remote_state.shared.outputs.domain
  postgres = data.terraform_remote_state.shared.outputs.postgres

  issuer = data.terraform_remote_state.accounts.outputs.issuer

  # The Authorization header value the backend pushes telemetry with. Its
  # `sensitive` marking is lost on the way through terraform_remote_state, so
  # sensitive() marks it again. Always use the local, never the data source's
  # attribute directly (see projects/accounts/).
  otlp_authorization = sensitive(data.terraform_remote_state.monitoring.outputs.otlp_authorization)

  hostname = "${local.project}.${local.domain}"

  # App Platform names regions by city ("nyc"), while VPCs etc. name the
  # datacenter ("nyc1"). Strip the trailing digits.
  app_region = regex("^[a-z]+", local.region)
}

# The DigitalOcean Project that groups this project's resources in the
# control panel. The database lives inside the shared cluster, which stays in
# the shared project.
resource "digitalocean_project" "crossword" {
  name        = local.project
  description = "crossword.cartergrove.me: build crossword puzzles with AI help, and play them."
  purpose     = "Web Application"
  environment = "Production"
  resources = [
    digitalocean_app.crossword.urn,
  ]
}

# --- Database ----------------------------------------------------------------

# A database and user named "crossword" on the shared cluster. After the first
# apply, grant the user CREATE on the public schema, or Flyway's migrations
# fail (see "One-time: crossword's first apply" in the README).
module "db" {
  source  = "../../modules/project-database"
  name    = local.project
  cluster = local.postgres
}

# --- App ---------------------------------------------------------------------

resource "digitalocean_app" "crossword" {
  spec {
    name   = local.project
    region = local.app_region

    # The custom domain. App Platform issues and renews the TLS certificate
    # itself once the DNS record below points at the app.
    domain {
      name = local.hostname
      type = "PRIMARY"
    }

    # Attach the app to the shared VPC, so the backend reaches Postgres on
    # `private_host` over the private network. The database firewall (in
    # shared/) trusts the whole VPC range, so nothing is opened to the
    # internet.
    vpc {
      id = data.terraform_remote_state.shared.outputs.vpc_id
    }

    # The backend, built from backend/Dockerfile on every push to main.
    # `source_dir` is the Docker build context; `dockerfile_path` is relative
    # to the repo root, not to source_dir.
    service {
      name               = "api"
      instance_size_slug = var.instance_size
      instance_count     = 1
      http_port          = 8080

      source_dir      = "backend"
      dockerfile_path = "backend/Dockerfile"
      github {
        repo           = "grovecj/crossword"
        branch         = "main"
        deploy_on_push = true
      }

      # A new deployment only takes traffic once this returns 200, so a build
      # that can't start (bad config, failed migration) never replaces a
      # working one. The health check reaches the container directly, so
      # /actuator needn't be routed publicly. The JVM takes a while to boot
      # on a small instance, and the word list is indexed at startup.
      health_check {
        http_path             = "/actuator/health"
        initial_delay_seconds = 30
        period_seconds        = 10
      }

      # SECRET values are encrypted by App Platform and hidden in its control
      # panel. The provider marks every env `value` sensitive, so plans print
      # none of them.
      env {
        key   = "SPRING_DATASOURCE_URL"
        value = "jdbc:postgresql://${local.postgres.private_host}:${local.postgres.port}/${module.db.database}?sslmode=require"
        scope = "RUN_TIME"
        type  = "GENERAL"
      }
      env {
        key   = "SPRING_DATASOURCE_USERNAME"
        value = module.db.user
        scope = "RUN_TIME"
        type  = "GENERAL"
      }
      env {
        key   = "SPRING_DATASOURCE_PASSWORD"
        value = module.db.password
        scope = "RUN_TIME"
        type  = "SECRET"
      }
      # Sign-in: the backend accepts tokens from the accounts service whose
      # `aud` is "crossword" (set in the app's own config). It checks them
      # against the issuer's public keys (JWKS), so it needs no auth secrets.
      env {
        key   = "AUTH_ISSUER"
        value = local.issuer
        scope = "RUN_TIME"
        type  = "GENERAL"
      }
      # The Claude API key for the AI features. The name is the one the
      # Anthropic SDKs read by default.
      env {
        key   = "ANTHROPIC_API_KEY"
        value = var.anthropic_api_key
        scope = "RUN_TIME"
        type  = "SECRET"
      }
      # Monitoring: the backend pushes its metrics to this OTLP endpoint,
      # sending the second value as its Authorization header (a token that
      # can only write telemetry; see monitoring/). With these unset it sends
      # nothing. The third labels everything it sends, so a run on someone's
      # laptop never mixes with this one's data.
      env {
        key   = "GRAFANA_OTLP_ENDPOINT"
        value = data.terraform_remote_state.monitoring.outputs.otlp_endpoint
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

    # The frontend, a single-page app built from frontend/ with Node (the
    # version comes from package.json's `engines`). App Platform runs
    # `npm ci` itself, then the build command, and serves `output_dir`
    # (relative to source_dir).
    static_site {
      name          = "web"
      source_dir    = "frontend"
      build_command = "npm run build"
      output_dir    = "dist"

      # Client-side routes (/puzzles/..., /auth/callback) have no file of
      # their own: serve index.html for them and let the router take over.
      catchall_document = "index.html"

      github {
        repo           = "grovecj/crossword"
        branch         = "main"
        deploy_on_push = true
      }

      # Vite bakes VITE_* variables into the bundle at build time. The app
      # defaults to the same issuer; setting it here keeps the two sides on
      # whatever projects/accounts says.
      env {
        key   = "VITE_AUTH_ISSUER"
        value = local.issuer
        scope = "BUILD_TIME"
        type  = "GENERAL"
      }
    }

    # Routing: App Platform sends each request to the rule with the longest
    # matching prefix. "/api" keeps its prefix (preserve_path_prefix): the
    # backend serves /api/**, locally too, where Vite proxies /api to it.
    # Everything else goes to the frontend.
    ingress {
      rule {
        component {
          name                 = "api"
          preserve_path_prefix = true
        }
        match {
          path {
            prefix = "/api"
          }
        }
      }

      rule {
        component {
          name = "web"
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

# crossword.cartergrove.me -> the app's own *.ondigitalocean.app hostname.
# default_ingress is a URL; a CNAME needs just the hostname, as an FQDN with a
# trailing dot.
resource "digitalocean_record" "crossword" {
  domain = local.domain
  type   = "CNAME"
  name   = local.project
  value  = "${trimprefix(digitalocean_app.crossword.default_ingress, "https://")}."
  ttl    = 3600
}
