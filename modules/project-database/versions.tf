terraform {
  # Modules declare which provider they need (so Terraform doesn't look for
  # "hashicorp/digitalocean") but not a version: the root module pins that.
  required_providers {
    digitalocean = {
      source = "digitalocean/digitalocean"
    }
  }
}
