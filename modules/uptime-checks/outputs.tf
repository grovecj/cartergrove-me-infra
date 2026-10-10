# For the README's budget arithmetic. A month is at most 31 days.
output "max_runs_per_month" {
  description = "The most runs these checks can use in a month (31 days), out of the free tier's allowance."
  value       = length(var.checks) * 31 * 24 * 60 / var.frequency_minutes
}
