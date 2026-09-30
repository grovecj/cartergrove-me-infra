# Credentials come from environment variables only (never commit them):
#   DIGITALOCEAN_TOKEN - DO API token
# This project manages no Spaces buckets, so the provider doesn't need the
# SPACES_* key (the s3 backend still needs AWS_* to reach the state bucket).
provider "digitalocean" {}

# The tls provider needs no configuration: it only does local crypto.
