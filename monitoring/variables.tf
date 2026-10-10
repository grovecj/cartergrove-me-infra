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
