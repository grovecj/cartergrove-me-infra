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
# Leaves out the cluster's admin (doadmin) credentials so project configs never
# use them. This is not a security boundary: the password is still in shared/'s
# state, which anyone who can read the state bucket (today: just you) can read.
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
