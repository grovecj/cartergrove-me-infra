# A database and a login user for one project on the shared Postgres cluster.
# Called from a project root module; the resources land in that project's state.

resource "digitalocean_database_db" "this" {
  cluster_id = var.cluster.id
  name       = var.name
}

# DigitalOcean generates the password; it is stored in the caller's state
# (private bucket) and exposed only through the sensitive outputs below.
# The user can't create tables until it's granted CREATE on the `public`
# schema, a one-time manual step: see modules/README.md.
resource "digitalocean_database_user" "this" {
  cluster_id = var.cluster.id
  name       = var.name

  # Reading a Postgres user back from the API leaves an empty `settings {}`
  # block in state (settings are for Kafka/OpenSearch ACLs). Without this, every
  # later plan tries to remove it, and the provider's PUT is rejected with
  # "missing the following required fields: user_settings".
  lifecycle {
    ignore_changes = [settings]
  }
}

locals {
  # Build the URL ourselves: the cluster's own `uri` is for the admin user.
  # urlencode() guards against characters in the password that mean something
  # in a URL. sslmode=require: managed Postgres only accepts TLS connections.
  credentials = "${digitalocean_database_user.this.name}:${urlencode(digitalocean_database_user.this.password)}"
  path        = "${digitalocean_database_db.this.name}?sslmode=require"
}
