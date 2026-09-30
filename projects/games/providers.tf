# Credentials come from environment variables only (never commit them):
#   DIGITALOCEAN_TOKEN                          - DO API token
#   SPACES_ACCESS_KEY_ID / SPACES_SECRET_ACCESS_KEY - for managing Spaces buckets
provider "digitalocean" {}
