# The stack's slug is the "<slug>" in https://<slug>.grafana.net, chosen at
# sign-up. It isn't a secret, but it's only known once the account exists, so
# there's no default: it comes from TF_VAR_grafana_stack_slug, which CI fills
# from the GRAFANA_STACK_SLUG repository variable.
variable "grafana_stack_slug" {
  description = "Slug of the Grafana Cloud stack, the <slug> in https://<slug>.grafana.net."
  type        = string

  # An unset GitHub variable becomes an empty TF_VAR_..., which would only
  # fail later with a confusing "stack not found". Fail the plan here instead.
  validation {
    condition     = length(var.grafana_stack_slug) > 0
    error_message = "grafana_stack_slug is empty: set the GRAFANA_STACK_SLUG repository variable (or TF_VAR_grafana_stack_slug locally)."
  }
}

# Where alerts are emailed. An address is not a credential, but this repo and
# its plan comments are public, and a published address gets spam. So there
# is no default and it is `sensitive`: plans print "(sensitive value)". It
# comes from TF_VAR_alert_email, which CI fills from the ALERT_EMAIL secret.
# It is stored in this root's state, in the private bucket.
variable "alert_email" {
  description = "Email address alert notifications are sent to."
  type        = string
  sensitive   = true

  # An unset GitHub secret becomes an empty TF_VAR_..., and a contact point
  # with no address would be created and tell nobody. Fail the plan instead.
  validation {
    condition     = can(regex("^[^@ ]+@[^@ ]+$", var.alert_email))
    error_message = "alert_email is not an email address: set the ALERT_EMAIL secret (or TF_VAR_alert_email locally)."
  }
}
