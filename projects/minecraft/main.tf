# minecraft.cartergrove.me: a Paper Minecraft server on one Droplet, with a
# firewall and a DNS record. What runs on the Droplet (docker-compose.yml, the
# Caddyfile, plugins) lives in its own repo (var.repo); this only builds the
# machine and points the name at it.
#
# Unlike the other projects, this is a Droplet (a plain virtual machine), not
# an App Platform app. App Platform only routes HTTP, and Minecraft speaks its
# own protocol on TCP 25565 (and UDP 19132 for Bedrock), so it needs a machine
# with a public IP and those ports open.

# Read the outputs of the shared/ root module from its state file. This is
# read-only: nothing here can change shared resources. The config must match
# shared/'s backend block (same bucket and endpoint, shared/'s key).
data "terraform_remote_state" "shared" {
  backend = "s3"

  config = {
    bucket    = "cartergrove-me-tfstate"
    key       = "shared/terraform.tfstate"
    endpoints = { s3 = "https://nyc3.digitaloceanspaces.com" }

    region                      = "us-east-1"
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_s3_checksum            = true
  }
}

locals {
  project = "minecraft"

  # Every resource in this project is named "<project>-..." and, where the
  # resource type supports tags, tagged with this.
  tags = ["project:${local.project}"]

  region   = data.terraform_remote_state.shared.outputs.region
  domain   = data.terraform_remote_state.shared.outputs.domain
  hostname = "${local.project}.${local.domain}"

  # "Anywhere": every IPv4 and every IPv6 address.
  anywhere = ["0.0.0.0/0", "::/0"]
}

# The DigitalOcean Project that groups this project's resources in the
# control panel. `resources` takes URNs ("do:droplet:<id>", ...). Firewalls
# and DNS records can't be assigned to a Project, so only the Droplet is listed.
resource "digitalocean_project" "minecraft" {
  name        = local.project
  description = "minecraft.cartergrove.me: Paper Minecraft server."
  purpose     = "Service or API"
  environment = "Production"
  resources = [
    digitalocean_droplet.server.urn,
  ]
}

# --- Droplet -----------------------------------------------------------------

# The SSH key that may log in as root. It was added to the account by hand
# (control panel -> Settings -> Security), so it's looked up, not managed.
data "digitalocean_ssh_key" "main" {
  name = var.ssh_key_name
}

# No `vpc_uuid`: the Droplet goes in the region's default VPC, not the shared
# one. The database firewall in shared/ trusts the whole shared VPC, and this
# machine has SSH open to the internet and needs no database, so it stays out.
resource "digitalocean_droplet" "server" {
  name     = "${local.project}-server"
  region   = local.region
  size     = var.size
  image    = "ubuntu-24-04-x64"
  ssh_keys = [data.digitalocean_ssh_key.main.id]
  tags     = local.tags

  # cloud-init: a script the Droplet runs once, on its very first boot. It
  # installs Docker, clones var.repo to /opt/minecraft and starts the server.
  # `templatefile` fills in the ${repo} and ${branch} placeholders.
  user_data = templatefile("${path.module}/cloud-init.yml", {
    repo   = var.repo
    branch = var.branch
  })

  lifecycle {
    # The world lives on this Droplet's disk (/opt/minecraft/data), so
    # destroying it deletes the world. Terraform refuses any plan that would.
    # To really delete it, remove this line first.
    prevent_destroy = true

    # Changing user_data normally replaces the Droplet. cloud-init only runs
    # on first boot anyway, so an edit to cloud-init.yml should not rebuild a
    # machine that has a world on it; it only affects the next new Droplet.
    ignore_changes = [user_data]
  }
}

# --- Firewall ----------------------------------------------------------------

# A firewall from the old grovecj/minecraft-server config still exists (its
# Droplet doesn't), so Terraform adopts it instead of creating a second one
# with the same name. An `import` block does that during a normal plan/apply;
# once the firewall is in state the block is a no-op and can stay. If the
# firewall is ever deleted by hand before the first apply, delete this block.
import {
  to = digitalocean_firewall.server
  id = "4d7bb0a1-8e44-41fd-9a94-caea36f9b388"
}

# A cloud firewall sits in front of the Droplet: anything not listed in an
# inbound rule never reaches it.
resource "digitalocean_firewall" "server" {
  name        = "${local.project}-firewall"
  droplet_ids = [digitalocean_droplet.server.id]

  # SSH
  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = local.anywhere
  }

  # Minecraft Java Edition
  inbound_rule {
    protocol         = "tcp"
    port_range       = "25565"
    source_addresses = local.anywhere
  }

  # Minecraft Bedrock Edition (GeyserMC)
  inbound_rule {
    protocol         = "udp"
    port_range       = "19132"
    source_addresses = local.anywhere
  }

  # HTTP. Caddy answers it to get its TLS certificate and to redirect to HTTPS.
  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = local.anywhere
  }

  # HTTPS (the BlueMap web map, via Caddy)
  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = local.anywhere
  }

  # Allow everything outbound: package installs, image pulls, plugin downloads.
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = local.anywhere
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = local.anywhere
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = local.anywhere
  }
}

# --- DNS ---------------------------------------------------------------------

# The old config's `minecraft` record is still in the zone too, pointing at the
# old Droplet's IP. Adopted for the same reason as the firewall: a second A
# record would send half the players to an address that's no longer ours. The
# id is "<domain>,<record id>" (`doctl compute domain records list <domain>`).
import {
  to = digitalocean_record.server
  id = "cartergrove.me,1809727932"
}

# minecraft.cartergrove.me -> the Droplet's public IP. Players use this name
# for both editions, and Caddy serves the web map on it. An A record (name ->
# IPv4 address) rather than the CNAME the App Platform projects use, because
# there's an address to point at instead of another hostname.
resource "digitalocean_record" "server" {
  domain = local.domain
  type   = "A"
  name   = local.project
  value  = digitalocean_droplet.server.ipv4_address
  ttl    = 300
}
