# Shared resources used by every *.cartergrove.me project: the DNS zone, VPC and
# managed Postgres cluster. Projects never create these; they read their ids
# from outputs.tf and build on top of them (subdomain records, databases, ...).

locals {
  project = "shared"
  tags    = ["project:${local.project}"]
}

# The DigitalOcean Project that groups the shared resources in the control
# panel. It's the "cartergrove.me" project that was created by hand, so it's
# looked up with a data source (read-only) rather than managed as a resource:
# Terraform only needs its id and never changes or deletes it.
data "digitalocean_project" "main" {
  id = "1e6842f5-9cde-4ed0-892c-a791988656c0"
}

# --- DNS ---------------------------------------------------------------------

# The cartergrove.me zone was created by hand when the registrar's nameservers
# were pointed at DigitalOcean (see README), so Terraform adopts it instead of
# creating it. An `import` block does that during a normal plan/apply; once the
# zone is in state the block is a no-op and can stay.
import {
  to = digitalocean_domain.main
  id = var.domain
}

# Only the zone itself is managed here. Records that already exist in it (the
# apex A record, www) are left alone: Terraform ignores what it doesn't manage.
# Each project adds its own subdomain records with `digitalocean_record`.
resource "digitalocean_domain" "main" {
  name = var.domain

  # Deleting the zone would take every record (and every site) down with it.
  lifecycle {
    prevent_destroy = true
  }
}

# --- Network -----------------------------------------------------------------

# A VPC is a private network. Resources in it talk to each other over private
# IPs that aren't reachable from the internet. The IP range is left for
# DigitalOcean to pick so it can't clash with another VPC in the account.
#
# It must be in the datacenter App Platform attaches apps to. Each App Platform
# region maps to exactly one: "nyc" -> nyc1 (see "How to Enable App Platform
# VPC" in DO's docs). An app in "nyc" can't join a VPC in nyc3.
resource "digitalocean_vpc" "main" {
  name        = "shared-${var.region}"
  region      = var.region
  description = "Private network for *.cartergrove.me projects."
}

# --- Postgres ----------------------------------------------------------------

# One managed Postgres cluster for every project. Each project gets its own
# database and user on it via modules/project-database; projects never create
# clusters. Single node, smallest size: no standby, fine for hobby traffic.
resource "digitalocean_database_cluster" "postgres" {
  name                 = "shared-postgres"
  engine               = "pg"
  version              = var.postgres_version
  size                 = var.postgres_size
  node_count           = 1
  region               = var.region
  private_network_uuid = digitalocean_vpc.main.id
  project_id           = data.digitalocean_project.main.id
  tags                 = local.tags

  # Destroying the cluster deletes every project's data.
  #
  # TEMPORARILY OFF to move the cluster from nyc3 to nyc1 (grovecj/cartergrove-me-infra#11).
  # The provider can migrate a cluster's region in place, but not its VPC
  # (private_network_uuid forces a new cluster), so the move is a replacement.
  # That's fine only because no project has data on it yet. Turn this back on
  # right after that apply.
  # lifecycle {
  #   prevent_destroy = true
  # }
}

# Trusted sources: only these may connect to the cluster at all (the database
# password is the second line of defence). The DO API stores ONE rule list per
# cluster and this resource replaces it wholesale, so it must live in exactly
# one place: here. Projects get access by attaching their App Platform app to
# the VPC above, whose whole range is trusted, rather than adding their own rule.
resource "digitalocean_database_firewall" "postgres" {
  cluster_id = digitalocean_database_cluster.postgres.id

  rule {
    type  = "ip_addr"
    value = digitalocean_vpc.main.ip_range
  }

  # Extra addresses, e.g. your home IP for running psql by hand.
  dynamic "rule" {
    for_each = var.postgres_trusted_ips
    content {
      type  = "ip_addr"
      value = rule.value
    }
  }
}
