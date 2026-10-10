# Outputs are the contract with project root modules: projects read them via
# `data "terraform_remote_state" "monitoring"` and pass them to their services
# as GRAFANA_OTLP_ENDPOINT and GRAFANA_OTLP_AUTHORIZATION.

output "otlp_endpoint" {
  description = "Base URL of the stack's OTLP gateway. Clients add the signal's path: /v1/metrics, /v1/logs or /v1/traces."
  value       = data.grafana_cloud_stack.main.otlp_url
}

# The gateway uses HTTP Basic auth: user = the stack's id, password = a token.
# Basic auth is the two joined by ":" and base64-encoded, sent as
# "Authorization: Basic <that>". Building the whole header value here means a
# service just copies one env var into one header. base64 is an encoding, not
# encryption: this value is as secret as the token inside it. `sensitive`
# makes Terraform print "(sensitive value)" for it, in this root module only.
#
# The marking does NOT travel through terraform_remote_state: a project that
# reads this output gets a plain string, and Terraform will print it in a
# plan like any other (hashicorp/terraform#29544). A project must mark it
# again where it reads it:
#   sensitive(data.terraform_remote_state.monitoring.outputs.otlp_authorization)
output "otlp_authorization" {
  description = "Value of the Authorization header for the OTLP gateway (write-only token)."
  value       = "Basic ${base64encode("${data.grafana_cloud_stack.main.id}:${grafana_cloud_access_policy_token.services_write.token}")}"
  sensitive   = true
}

# Not a secret: a URL and a user id, which do nothing without a token that
# may read. Used to check the write token can't (see the README).
output "prometheus" {
  description = "The stack's metrics (Prometheus) query endpoint and its Basic auth user id."
  value = {
    url     = data.grafana_cloud_stack.main.prometheus_url
    user_id = data.grafana_cloud_stack.main.prometheus_user_id
  }
}
