variable "repo" {
  description = "GitHub repo (\"owner/name\") holding the page, with index.html at its root."
  type        = string
  default     = "grovecj/schooners-cams"
}

variable "branch" {
  description = "Branch of var.repo to serve. Pushing to it redeploys the site."
  type        = string
  default     = "main"
}
