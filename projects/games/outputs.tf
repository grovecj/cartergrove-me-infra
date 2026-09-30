# Outputs are the contract with the game repos' CD workflows (e.g.
# grovecj/Match-3#24): read them with `terraform output` rather than
# hard-coding names and URLs there.

output "hostname" {
  description = "Public hostname of the games hub."
  value       = local.hostname
}

output "app_id" {
  description = "App Platform app id (for `doctl apps ...`)."
  value       = digitalocean_app.hub.id
}

output "app_url" {
  description = "Public URL of the games hub."
  value       = "https://${local.hostname}"
}

output "app_default_url" {
  description = "The app's own *.ondigitalocean.app URL; works before DNS and TLS for the custom domain are ready."
  value       = digitalocean_app.hub.default_ingress
}

# The trailing slash matters: a Unity web build loads "Build/..." relative to
# the page, and relative to "/match3" that would be "/Build/...".
output "game_urls" {
  description = "Public URL of each game, keyed like var.games."
  value       = { for key, game in var.games : key => "https://${local.hostname}/${key}/" }
}

output "downloads_bucket" {
  description = "Spaces bucket for downloadable builds; upload to <game key>/<file>."
  value       = digitalocean_spaces_bucket.downloads.name
}

output "downloads_bucket_region" {
  description = "Region of the downloads bucket."
  value       = digitalocean_spaces_bucket.downloads.region
}

output "downloads_bucket_endpoint" {
  description = "S3 API endpoint for uploads (aws s3 --endpoint-url, s3cmd --host)."
  value       = "https://${digitalocean_spaces_bucket.downloads.endpoint}"
}

output "downloads_cdn_url" {
  description = "Base URL players download from: <this>/<game key>/<file>."
  value       = "https://${digitalocean_cdn.downloads.endpoint}"
}
