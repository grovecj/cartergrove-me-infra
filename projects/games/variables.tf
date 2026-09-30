# The games hosted on the hub. Adding a game = adding an entry here (then
# `terraform apply`). The key becomes the component name, the URL path
# (games.cartergrove.me/<key>/) and the downloads prefix (<key>/...).
variable "games" {
  description = "Games served by the hub, keyed by URL path. The branch must contain a ready-made web build with index.html at its root."
  type = map(object({
    repo   = string # "owner/name" on GitHub
    branch = string
  }))

  default = {
    match3 = { repo = "grovecj/Match-3", branch = "web-build" }
  }

  # App Platform component names: 2-32 lowercase letters, digits and dashes,
  # starting with a letter. "hub" is taken by the landing page.
  validation {
    condition = alltrue([
      for key in keys(var.games) : can(regex("^[a-z][a-z0-9-]{0,30}[a-z0-9]$", key)) && key != "hub"
    ])
    error_message = "Game keys must be 2-32 lowercase letters, digits or dashes, start with a letter, and not be \"hub\"."
  }
}
