# The Droplet outputs are null while var.enabled is off. `one(list)` gives
# the list's only element, or null for an empty list.

output "hostname" {
  description = "Server address for both editions (Java: default port 25565; Bedrock: port 19132)."
  value       = local.hostname
}

output "bluemap_url" {
  description = "BlueMap web map URL."
  value       = "https://${local.hostname}"
}

output "droplet_id" {
  description = "Droplet id (for `doctl compute droplet ...`)."
  value       = one(digitalocean_droplet.server[*].id)
}

output "droplet_ip" {
  description = "Public IPv4 address of the Droplet."
  value       = one(digitalocean_droplet.server[*].ipv4_address)
}

output "ssh_command" {
  description = "SSH command to connect to the server."
  value       = var.enabled ? "ssh root@${digitalocean_droplet.server[0].ipv4_address}" : null
}
