output "database" {
  description = "Database name."
  value       = digitalocean_database_db.this.name
}

output "user" {
  description = "Database user name."
  value       = digitalocean_database_user.this.name
}

output "password" {
  description = "Database user password."
  value       = digitalocean_database_user.this.password
  sensitive   = true
}

# Use this one from apps attached to the shared VPC (the normal case).
output "private_uri" {
  description = "postgresql:// connection string over the VPC."
  value       = "postgresql://${local.credentials}@${var.cluster.private_host}:${var.cluster.port}/${local.path}"
  sensitive   = true
}

# Only works from an address in shared/'s postgres_trusted_ips.
output "uri" {
  description = "postgresql:// connection string over the public internet."
  value       = "postgresql://${local.credentials}@${var.cluster.host}:${var.cluster.port}/${local.path}"
  sensitive   = true
}
