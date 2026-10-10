variable "checks" {
  description = "HTTP checks to run, keyed by name. The key becomes the check's `job` label in Grafana, so keep it short and readable (\"match3-api health\")."

  type = map(object({
    # The URL to GET. Must be public and read-only: checks carry no credentials.
    url = string

    # Which service this URL says something about, as the `service` label on
    # the check's metrics. Use the name the service reports its own metrics
    # under ("match3-api", "accounts"), so a dashboard or alert can put the
    # outside view next to the inside one.
    service = string

    # Regular expressions (Go/RE2 syntax) the response body must match, all of
    # them. Empty means any body will do: the check is only "answers 200".
    body_must_match = optional(list(string), [])
  }))

  # Grafana's limit on a check's label values, and `service` is one.
  validation {
    condition     = alltrue([for check in values(var.checks) : length(check.service) >= 1 && length(check.service) <= 32])
    error_message = "Each check's service must be 1-32 characters (Grafana's limit for a check label)."
  }
}

# One probe location, not several: every location runs every check, so two
# locations doubles the runs and the free tier's 100k a month goes quickly
# (see "Uptime checks" in the README). The cost of one is that a problem at
# the probe's end looks like a problem at ours; alerting on two failures in a
# row covers the usual blip.
variable "probe" {
  description = "Name of the public probe location that runs the checks, as Grafana lists them (Testing & synthetics -> Synthetics -> Probes)."
  type        = string
  default     = "Ohio"
}

variable "frequency_minutes" {
  description = "Minutes between runs of each check."
  type        = number
  default     = 5

  # 60 is Grafana's maximum (frequency is at most 3,600,000 ms).
  validation {
    condition     = var.frequency_minutes >= 1 && var.frequency_minutes <= 60 && floor(var.frequency_minutes) == var.frequency_minutes
    error_message = "frequency_minutes must be a whole number from 1 to 60."
  }
}

variable "timeout_seconds" {
  description = "How long a check waits for the response before it counts as failed."
  type        = number
  default     = 10

  # Grafana accepts 1 to 180 seconds (timeout is 1,000 to 180,000 ms).
  validation {
    condition     = var.timeout_seconds >= 1 && var.timeout_seconds <= 180 && floor(var.timeout_seconds) == var.timeout_seconds
    error_message = "timeout_seconds must be a whole number from 1 to 180."
  }
}
