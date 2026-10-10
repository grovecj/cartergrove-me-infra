# The games hosted on the hub. Adding a game = adding an entry here (then
# `terraform apply`). The key becomes the component name, the URL path
# (games.cartergrove.me/<key>/) and the downloads prefix (<key>/...).
#
# A game can also declare a backend with `api = { repo = "owner/name" }`. That
# adds a service component "<key>-api" at games.cartergrove.me/<key>/api, built
# from that repo's Dockerfile, plus a database and user named <key> on the
# shared Postgres cluster. Games without `api` get neither.
variable "games" {
  description = "Games served by the hub, keyed by URL path. The branch must contain a ready-made web build with index.html at its root."

  # `optional(type, default)` lets an entry leave an attribute out. Left out,
  # `api` is null; inside it, `branch` and `instance_size` take their defaults.
  type = map(object({
    repo   = string # "owner/name" on GitHub
    branch = string

    api = optional(object({
      repo   = string # built from its Dockerfile
      branch = optional(string, "main")
      # The smallest (512 MiB) is enough for a low-traffic Spring Boot
      # service; if it gets OOM-killed, go up to "apps-s-1vcpu-1gb".
      instance_size = optional(string, "apps-s-1vcpu-0.5gb")
    }))
  }))

  default = {
    match3 = {
      repo   = "grovecj/Match-3"
      branch = "web-build"
      api    = { repo = "grovecj/match-3-api" }
    }
  }

  # App Platform component names: 2-32 lowercase letters, digits and dashes,
  # starting with a letter. "hub" is taken by the landing page. Keys stop at
  # 28 so the names built from them fit in 32 too: the API component
  # "<key>-api", and the uptime checks' service labels "<key>-api" and
  # "<key>-web" (Grafana's limit for a check label is also 32).
  validation {
    condition = alltrue([
      for key in keys(var.games) : can(regex("^[a-z][a-z0-9-]{0,26}[a-z0-9]$", key)) && key != "hub"
    ])
    error_message = "Game keys must be 2-28 lowercase letters, digits or dashes, start with a letter, and not be \"hub\"."
  }
}
