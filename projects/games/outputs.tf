output "hostname" {
  description = "Public hostname of the games hub."
  value       = "${local.project}.${local.domain}"
}
