variable "size" {
  description = "Droplet size slug (`doctl compute size list`). The server's Java heap is set in the repo's docker-compose.yml (MEMORY); keep it about 1 GB below this."
  type        = string
  default     = "s-2vcpu-4gb"
}

variable "ssh_key_name" {
  description = "Name of the SSH key in the DigitalOcean account that may log in as root."
  type        = string
  default     = "1PASSWORD-DigitalOcean"
}

# cloud-init clones this over HTTPS without credentials, so it must be public.
variable "repo" {
  description = "GitHub repo (\"owner/name\") holding docker-compose.yml and the Caddyfile at its root. Only read on the Droplet's first boot."
  type        = string
  default     = "grovecj/minecraft-server"
}

variable "branch" {
  description = "Branch of var.repo to clone on first boot."
  type        = string
  default     = "main"
}
