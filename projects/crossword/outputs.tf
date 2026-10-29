output "hostname" {
  description = "Public hostname of the crossword app."
  value       = local.hostname
}

output "url" {
  description = "Public URL of the crossword app. The backend is under <url>/api."
  value       = "https://${local.hostname}"
}

output "app_id" {
  description = "App Platform app id (for `doctl apps ...`)."
  value       = digitalocean_app.crossword.id
}

output "app_default_url" {
  description = "The app's own *.ondigitalocean.app URL; works before DNS and TLS for the custom domain are ready."
  value       = digitalocean_app.crossword.default_ingress
}
