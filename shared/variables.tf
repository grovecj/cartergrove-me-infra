variable "region" {
  description = "DigitalOcean region used by shared resources and, by default, every project."
  type        = string
  default     = "nyc3"
}

variable "domain" {
  description = "Apex domain whose subdomains host the projects."
  type        = string
  default     = "cartergrove.me"
}

variable "postgres_version" {
  description = "Major version of the shared Postgres cluster."
  type        = string
  default     = "18"
}

variable "postgres_size" {
  description = "Node size of the shared Postgres cluster (`doctl databases options slugs --engine pg`)."
  type        = string
  default     = "db-s-1vcpu-1gb"
}

variable "postgres_trusted_ips" {
  description = "Extra IPs/CIDRs allowed to reach Postgres besides the VPC, e.g. [\"203.0.113.7\"] for psql from home."
  type        = list(string)
  default     = []
}
