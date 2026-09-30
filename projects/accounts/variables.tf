# Google OAuth client for "Sign in with Google" (see bootstrap/README.md for
# creating it). There are no defaults: they come from TF_VAR_google_client_id /
# TF_VAR_google_client_secret, which CI fills from repository secrets.
# `sensitive` makes Terraform print "(sensitive value)" instead of the value in
# plans and errors. The repo is public, and so are its plan comments.

variable "google_client_id" {
  description = "Google OAuth client id for auth.cartergrove.me."
  type        = string
  sensitive   = true

  # An unset GitHub secret becomes an empty TF_VAR_..., which Terraform would
  # happily accept. Fail the plan instead of deploying a broken sign-in.
  validation {
    condition     = length(var.google_client_id) > 0
    error_message = "google_client_id is empty: set the GOOGLE_CLIENT_ID secret (or TF_VAR_google_client_id locally)."
  }
}

variable "google_client_secret" {
  description = "Google OAuth client secret for auth.cartergrove.me."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.google_client_secret) > 0
    error_message = "google_client_secret is empty: set the GOOGLE_CLIENT_SECRET secret (or TF_VAR_google_client_secret locally)."
  }
}

# App Platform instance size. The smallest (512 MiB) is enough for a
# low-traffic Spring Boot service; if it gets OOM-killed, go up to
# "apps-s-1vcpu-1gb". `doctl apps tier instance-size list` shows the options.
variable "instance_size" {
  description = "App Platform instance size slug for the accounts service."
  type        = string
  default     = "apps-s-1vcpu-0.5gb"
}
