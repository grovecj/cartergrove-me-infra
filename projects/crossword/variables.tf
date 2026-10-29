# The Claude API key for the AI features (theme brainstorming, clue
# suggestions, review). There's no default: it comes from
# TF_VAR_anthropic_api_key, which CI fills from the ANTHROPIC_API_KEY secret.
# `sensitive` makes Terraform print "(sensitive value)" instead of the value
# in plans and errors. The repo is public, and so are its plan comments.
variable "anthropic_api_key" {
  description = "Claude API key for crossword.cartergrove.me's AI features."
  type        = string
  sensitive   = true

  # An unset GitHub secret becomes an empty TF_VAR_..., which Terraform would
  # happily accept. Fail the plan instead of deploying broken AI features.
  validation {
    condition     = length(var.anthropic_api_key) > 0
    error_message = "anthropic_api_key is empty: set the ANTHROPIC_API_KEY secret (or TF_VAR_anthropic_api_key locally)."
  }
}

# App Platform instance size for the backend. The smallest (512 MiB) is
# enough: the in-memory word index is a few tens of MiB. If it gets
# OOM-killed, go up to "apps-s-1vcpu-1gb". `doctl apps tier instance-size
# list` shows the options.
variable "instance_size" {
  description = "App Platform instance size slug for the crossword backend."
  type        = string
  default     = "apps-s-1vcpu-0.5gb"
}
