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
  value       = digitalocean_droplet.server.id
}

output "droplet_ip" {
  description = "Public IPv4 address of the Droplet."
  value       = digitalocean_droplet.server.ipv4_address
}

output "ssh_command" {
  description = "SSH command to connect to the server."
  value       = "ssh root@${digitalocean_droplet.server.ipv4_address}"
}
