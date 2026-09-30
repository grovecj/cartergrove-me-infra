variable "name" {
  description = "Name of the database and of its user, usually the project name (e.g. \"games\")."
  type        = string
}

variable "cluster" {
  description = "The shared cluster; pass data.terraform_remote_state.shared.outputs.postgres."
  type = object({
    id           = string
    host         = string
    private_host = string
    port         = number
  })
}
