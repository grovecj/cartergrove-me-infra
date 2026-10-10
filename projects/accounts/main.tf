# auth.cartergrove.me: the shared accounts service (grovecj/accounts), which
# every *.cartergrove.me project signs users in through. One App Platform
# service built from the repo's Dockerfile, a database on the shared Postgres
# cluster (no cluster of its own), and the key it signs JWTs with.

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

# The monitoring/ root module's outputs: where the service pushes its
# telemetry (Grafana Cloud's OTLP gateway) and the credentials to do it with.
# Same bucket, monitoring's key. monitoring/ must have been applied once, or
# this fails with "Unable to find remote state".
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

locals {
  project = "accounts"

  # Every resource in this project is named "<project>-..." and, where the
  # resource type supports tags, tagged with this. (None of the ones below do.)
  tags = ["project:${local.project}"]

  region   = data.terraform_remote_state.shared.outputs.region
  domain   = data.terraform_remote_state.shared.outputs.domain
  postgres = data.terraform_remote_state.shared.outputs.postgres

  # "auth", not "accounts": the hostname is what users see when they sign in.
  hostname = "auth.${local.domain}"
  issuer   = "https://${local.hostname}"

  # App Platform names regions by city ("nyc"), while Droplets, Spaces, VPCs
  # etc. name the datacenter ("nyc1"). Strip the trailing digits. The shared
  # VPC is in the one datacenter "nyc" apps can attach to (see shared/).
  app_region = regex("^[a-z]+", local.region)
}

# The DigitalOcean Project that groups this project's resources in the
# control panel. `resources` takes URNs ("do:app:<id>", ...). The database
# lives inside the shared cluster, which stays in the shared project.
resource "digitalocean_project" "accounts" {
  name        = local.project
  description = "auth.cartergrove.me: shared sign-in for every *.cartergrove.me project."
  purpose     = "Service or API"
  environment = "Production"
  resources = [
    digitalocean_app.accounts.urn,
  ]
}

# --- Database ----------------------------------------------------------------

# A database and user named "accounts" on the shared cluster. After the first
# apply, grant the user CREATE on the public schema, or Flyway's migrations
# fail (see "One-time: database grant" in the README).
module "db" {
  source  = "../../modules/project-database"
  name    = local.project
  cluster = local.postgres
}

# --- JWT signing key ---------------------------------------------------------

# The key the service signs access and ID tokens with (ES256). Other projects
# verify tokens with its public half, which the service publishes at its JWKS
# endpoint. Terraform generates it, so it lives in this project's state (the
# private state bucket) and nowhere else. To rotate it:
#   terraform apply -replace=tls_private_key.jwt
# That redeploys the app with the new key, and every access token signed with
# the old one stops validating (they live 15 minutes, so users just refresh).
resource "tls_private_key" "jwt" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

# --- App ---------------------------------------------------------------------

resource "digitalocean_app" "accounts" {
  spec {
    name   = local.project
    region = local.app_region

    # The custom domain. App Platform issues and renews the TLS certificate
    # itself once the DNS record below points at the app.
    domain {
      name = local.hostname
      type = "PRIMARY"
    }

    # Attach the app to the shared VPC. Its outbound traffic to private IPs in
    # that VPC then goes over the private network, which is how it reaches
    # Postgres on `private_host`. The database firewall (in shared/) trusts
    # the whole VPC range, so nothing is opened to the internet.
    vpc {
      id = data.terraform_remote_state.shared.outputs.vpc_id
    }

    service {
      name               = "web"
      instance_size_slug = var.instance_size
      instance_count     = 1
      http_port          = 8080

      # Built from the repo's Dockerfile on every push to main.
      dockerfile_path = "Dockerfile"
      github {
        repo           = "grovecj/accounts"
        branch         = "main"
        deploy_on_push = true
      }

      # A new deployment only takes traffic once this returns 200, so a build
      # that can't start (bad config, failed migration) never replaces a
      # working one. The JVM takes a while to boot on a small instance.
      health_check {
        http_path             = "/actuator/health"
        initial_delay_seconds = 30
        period_seconds        = 10
      }

      # Environment variables. SECRET ones are encrypted by App Platform and
      # hidden in its control panel. Terraform hides them in plans because
      # they come from sensitive values (the database password, the key,
      # sensitive variables). The provider marks every env `value` sensitive
      # anyway.
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
      env {
        key   = "GOOGLE_CLIENT_ID"
        value = var.google_client_id
        scope = "RUN_TIME"
        type  = "SECRET"
      }
      env {
        key   = "GOOGLE_CLIENT_SECRET"
        value = var.google_client_secret
        scope = "RUN_TIME"
        type  = "SECRET"
      }
      # PKCS#8 ("BEGIN PRIVATE KEY"), the PEM flavour Java reads natively.
      env {
        key   = "AUTH_SIGNING_KEY_PEM"
        value = tls_private_key.jwt.private_key_pem_pkcs8
        scope = "RUN_TIME"
        type  = "SECRET"
      }
      env {
        key   = "AUTH_ISSUER"
        value = local.issuer
        scope = "RUN_TIME"
        type  = "GENERAL"
      }
      # Monitoring: the service pushes its metrics to this OTLP endpoint,
      # sending the second value as its Authorization header. That value
      # holds a token that can only write telemetry (see monitoring/). With
      # these unset the service sends nothing. The third labels everything
      # it sends, so a run on someone's laptop ("local", the service's
      # default) never mixes with this one's data.
      env {
        key   = "GRAFANA_OTLP_ENDPOINT"
        value = data.terraform_remote_state.monitoring.outputs.otlp_endpoint
        scope = "RUN_TIME"
        type  = "GENERAL"
      }
      env {
        key   = "GRAFANA_OTLP_AUTHORIZATION"
        value = data.terraform_remote_state.monitoring.outputs.otlp_authorization
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

    ingress {
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

# auth.cartergrove.me -> the app's own *.ondigitalocean.app hostname.
# default_ingress is a URL ("https://accounts-xxxxx.ondigitalocean.app"); a
# CNAME needs just the hostname, as an FQDN with a trailing dot.
resource "digitalocean_record" "accounts" {
  domain = local.domain
  type   = "CNAME"
  name   = "auth"
  value  = "${trimprefix(digitalocean_app.accounts.default_ingress, "https://")}."
  ttl    = 3600
}
