terraform {
  # Modules declare which provider they need (so Terraform doesn't look for
  # "hashicorp/grafana") but not a version: the root module pins that.
  required_providers {
    grafana = {
      source = "grafana/grafana"
    }
  }
}
