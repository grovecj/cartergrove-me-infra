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
