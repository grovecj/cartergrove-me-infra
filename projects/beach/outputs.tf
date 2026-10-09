output "hostname" {
  description = "Public hostname of the site."
  value       = local.hostname
}

output "app_id" {
  description = "App Platform app id (for `doctl apps ...`)."
  value       = digitalocean_app.site.id
}

output "app_url" {
  description = "Public URL of the site."
  value       = "https://${local.hostname}"
}

output "app_default_url" {
  description = "The app's own *.ondigitalocean.app URL; works before DNS and TLS for the custom domain are ready."
  value       = digitalocean_app.site.default_ingress
}
