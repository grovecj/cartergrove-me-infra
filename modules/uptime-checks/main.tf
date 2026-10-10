# Uptime checks: Grafana Cloud Synthetic Monitoring requests each URL from
# outside, on a schedule, and records success and latency. See "Uptime
# checks" in the README for what's checked and the free-tier arithmetic.
#
# The caller's grafana provider must be configured for Synthetic Monitoring
# (sm_url and sm_access_token, both from monitoring/'s outputs).

# Probe locations are referred to by a numeric id, which nobody remembers.
# This data source lists the public ones as { name => id }.
data "grafana_synthetic_monitoring_probes" "all" {}

resource "grafana_synthetic_monitoring_check" "http" {
  for_each = var.checks

  # `job` and `target` (the URL) together identify the check, and are the
  # `job` and `instance` labels on everything it records.
  job    = each.key
  target = each.value.url

  probes = [data.grafana_synthetic_monitoring_probes.all.probes[var.probe]]

  # Both are in milliseconds.
  frequency = var.frequency_minutes * 60 * 1000
  timeout   = var.timeout_seconds * 1000

  # Shows up as `label_service` on the check's `sm_check_info` series, which
  # queries join to the other metrics on job and instance. Checks may have
  # at most 5 labels.
  labels = {
    service = each.value.service
  }

  # true is the default; written out because it's a budget decision. The
  # basic set (did it succeed, how long did it take, status code, TLS
  # certificate expiry) is everything the dashboard and alerts use. false
  # adds a breakdown per request phase, and several times the series.
  basic_metrics_only = true

  # Alerts are our own rules (see the alerting issue), not the built-in ones
  # this setting switches on. "none" is the default.
  alert_sensitivity = "none"

  settings {
    http {
      method = "GET"

      # Anything but 200 fails. Redirects are followed, and it's the final
      # answer that must be 200.
      valid_status_codes = [200]

      # Fail if the URL was somehow answered without TLS. Over TLS, the probe
      # also records when the certificate expires, for free.
      fail_if_not_ssl = true

      # Null (not an empty list) when there's nothing to match, so the
      # provider sees the argument as unset.
      fail_if_body_not_matches_regexp = length(each.value.body_must_match) > 0 ? each.value.body_must_match : null
    }
  }

  lifecycle {
    # Without this, a wrong name fails with a bare "Invalid index".
    precondition {
      condition     = contains(keys(data.grafana_synthetic_monitoring_probes.all.probes), var.probe)
      error_message = "No public probe is called \"${var.probe}\". Available: ${join(", ", keys(data.grafana_synthetic_monitoring_probes.all.probes))}."
    }
  }
}
