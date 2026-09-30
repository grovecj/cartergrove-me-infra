# Outputs are the contract with project root modules: projects read them via
# `data "terraform_remote_state" "shared"` instead of hard-coding values.

output "region" {
  description = "Region projects should create their resources in."
  value       = var.region
}

output "domain" {
  description = "Apex domain; projects create their own subdomain records in this zone."
  value       = digitalocean_domain.main.name
}

output "vpc_id" {
  description = "VPC projects attach their apps to; its whole range may reach Postgres."
  value       = digitalocean_vpc.main.id
}

output "vpc_ip_range" {
  description = "CIDR of the shared VPC."
  value       = digitalocean_vpc.main.ip_range
}

# Grouped so it can be passed straight to modules/project-database as `cluster`.
# Deliberately excludes the cluster's admin (doadmin) credentials: projects get
# their own user from the module and never see the admin password.
output "postgres" {
  description = "Shared Postgres cluster: id, name, public/private host and port."
  value = {
    id           = digitalocean_database_cluster.postgres.id
    name         = digitalocean_database_cluster.postgres.name
    host         = digitalocean_database_cluster.postgres.host
    private_host = digitalocean_database_cluster.postgres.private_host
    port         = digitalocean_database_cluster.postgres.port
  }
}
