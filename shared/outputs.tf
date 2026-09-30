# Outputs are the contract with project root modules: projects read them via
# `data "terraform_remote_state" "shared"` instead of hard-coding values.

output "region" {
  description = "Region projects should create their resources in."
  value       = var.region
}

output "domain" {
  description = "Apex domain; projects create their own subdomain records in this zone."
  value       = var.domain
}
