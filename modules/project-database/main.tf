# A database and a login user for one project on the shared Postgres cluster.
# Called from a project root module; the resources land in that project's state.

resource "digitalocean_database_db" "this" {
  cluster_id = var.cluster.id
  name       = var.name
}

# DigitalOcean generates the password; it is stored in the caller's state
# (private bucket) and exposed only through the sensitive outputs below.
resource "digitalocean_database_user" "this" {
  cluster_id = var.cluster.id
  name       = var.name
}

locals {
  # Build the URL ourselves: the cluster's own `uri` is for the admin user.
  # urlencode() guards against characters in the password that mean something
  # in a URL. sslmode=require: managed Postgres only accepts TLS connections.
  credentials = "${digitalocean_database_user.this.name}:${urlencode(digitalocean_database_user.this.password)}"
  path        = "${digitalocean_database_db.this.name}?sslmode=require"
}
