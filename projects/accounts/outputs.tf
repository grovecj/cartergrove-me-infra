# Outputs are the contract with other projects (e.g. the Match-3 API, which
# validates tokens issued here): read them with `terraform output` rather than
# hard-coding names and URLs there.

output "hostname" {
  description = "Public hostname of the accounts service."
  value       = local.hostname
}

output "issuer" {
  description = "OIDC issuer; tokens' `iss` claim. Discovery is at <issuer>/.well-known/openid-configuration."
  value       = local.issuer
}

output "app_id" {
  description = "App Platform app id (for `doctl apps ...`)."
  value       = digitalocean_app.accounts.id
}

output "app_default_url" {
  description = "The app's own *.ondigitalocean.app URL; works before DNS and TLS for the custom domain are ready."
  value       = digitalocean_app.accounts.default_ingress
}

# The public half of the JWT signing key is not a secret. Clients should still
# fetch it from the JWKS endpoint, which keeps working across rotations.
output "jwt_public_key_pem" {
  description = "Public key that verifies the tokens the service signs."
  value       = tls_private_key.jwt.public_key_pem
}
