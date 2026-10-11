# Alerts: getting told when something is wrong, by email, instead of finding
# out from the dashboard. There are few, and each one means "a person should
# look". An alert that fires and needs nothing done teaches you to ignore
# alerts, which is worse than not having it. So they're about *symptoms* (a
# player can't reach it, requests are failing), not causes (CPU is high): a
# cause that hurts nobody isn't worth an email, and one that does shows up as
# a symptom anyway. See "Alerts" in the README for what each one means and
# the first thing to check.
#
# Three pieces:
#   rules          - a query and a threshold, evaluated every minute.
#   contact point  - where a notification goes (one email address).
#   policy         - which alerts go to which contact point, and how they're
#                    batched into notifications.

# Looking the data sources up by uid, instead of writing the uids into the
# rules, means a plan fails if one isn't there. Both come with the stack:
# its metrics, and Grafana's own figures about the account (how many series
# we're storing).
data "grafana_data_source" "metrics" {
  provider = grafana.stack
  uid      = "grafanacloud-prom"
}

data "grafana_data_source" "usage" {
  provider = grafana.stack
  uid      = "grafanacloud-usage"
}

locals {
  # Only what runs in production. A service started on a laptop with the
  # export switched on reports as "local" and can't set an alert off.
  production = "deployment_environment=\"production\""

  # Requests that count towards the error rate: everything but /actuator.
  # App Platform asks /actuator/health every few seconds, and those would
  # outnumber real requests and water the error rate down.
  requests = "http_server_requests_milliseconds_count{${local.production}, uri!~\"/actuator.*\"}"
  failures = "http_server_requests_milliseconds_count{${local.production}, uri!~\"/actuator.*\", status=~\"5..\"}"

  # The policy below groups by a `service` label, so every rule's result has
  # to carry one, with the same values everywhere. Services call theirs
  # `service_name` (from OTLP's service.name), so their queries are wrapped
  # in label_replace(<query><this>, which copies it.
  as_service = ", \"service\", \"$1\", \"service_name\", \"(.*)\")"

  # Uptime checks keep theirs on a separate series, sm_check_info, as
  # `label_service`. Multiplying a check's metric by this (it's always 1)
  # copies the label over without changing the value.
  check_service = "on (job, instance) group_left (service) label_replace(max by (job, instance, label_service) (sm_check_info), \"service\", \"$1\", \"label_service\", \"(.*)\")"

  # The free tier's allowance of active series (see "Free-tier budget" in the
  # README).
  series_allowance = 10000

  dashboard_url = "${data.grafana_cloud_stack.main.url}/d/${grafana_dashboard.services.uid}"

  # Each rule is a query that gives a number per service (or per check), and
  # the test that number has to meet *continuously* for `for` before the
  # alert fires. A rule that has met it for less is "pending": one bad
  # minute sends nothing.
  #
  # panel is the id of the dashboard panel that shows the same thing (the
  # "id" fields in dashboards/services.json), for the button in the email.
  # null where the dashboard has nothing to show: it is about our services,
  # not about the account.
  #
  # no_data says what an empty result means. Some of these queries only
  # return something when there's a problem, so empty is "OK". The others
  # always have a value while monitoring itself works, so empty is its own
  # alert ("NoData"): the thing that would have told us is broken.
  alerts = [
    {
      name = "Service down"
      # probe_success is 1 when a check's last run passed and 0 when it
      # failed. Checks run every 5 minutes (modules/uptime-checks), so
      # failing for 6 minutes on end takes two failed runs in a row: one
      # timeout on the probe's side isn't an outage.
      expr        = "max by (job, instance) (probe_success) * ${local.check_service}"
      datasource  = data.grafana_data_source.metrics.uid
      test        = "lt"
      threshold   = 1
      for         = "6m"
      no_data     = "NoData"
      labels      = {}
      panel       = 2
      summary     = "{{ $labels.job }} is failing: {{ $labels.instance }}"
      description = "The uptime check has failed twice in a row, so players probably can't reach it."
    },
    {
      name = "High error rate"
      # Share of requests answered with a 5xx, in percent, over the last 5
      # minutes. The `and` drops a service with fewer than 10 requests in
      # that time: when one request arrives at 3 a.m. and fails, that's 100%
      # and no reason to wake anyone.
      expr        = "label_replace(100 * sum by (service_name) (rate(${local.failures}[5m])) / sum by (service_name) (rate(${local.requests}[5m])) and sum by (service_name) (increase(${local.requests}[5m])) >= 10${local.as_service}"
      datasource  = data.grafana_data_source.metrics.uid
      test        = "gt"
      threshold   = 5
      for         = "10m"
      no_data     = "OK"
      labels      = {}
      panel       = 8
      summary     = "{{ $labels.service }}: {{ printf \"%.0f\" $values.B.Value }}% of requests are failing"
      description = "More than 5% of requests have ended in a 5xx for 10 minutes."
    },
    {
      name = "Connection pool exhausted"
      # Requests waiting for a database connection, or every connection in
      # use. Either means the next request queues. `active >= max` is
      # compared per running copy, each of which has its own pool.
      expr        = "label_replace(max by (service_name) (hikaricp_connections_pending{${local.production}}) > 0 or max by (service_name) (hikaricp_connections_active{${local.production}} >= hikaricp_connections_max{${local.production}})${local.as_service}"
      datasource  = data.grafana_data_source.metrics.uid
      test        = "gt"
      threshold   = 0
      for         = "5m"
      no_data     = "OK"
      labels      = {}
      panel       = 14
      summary     = "{{ $labels.service }} has run out of database connections"
      description = "For 5 minutes, requests have been waiting for a connection or all of them were in use."
    },
    {
      name = "No metrics"
      # Monitoring the monitoring. Every other rule about a service's own
      # metrics goes quiet when the metrics stop, and quiet looks like
      # healthy. This is: services that reported at some point in the last
      # day, `unless` they're reporting now. "Now" already reaches back 5
      # minutes (how long Prometheus keeps using a series' last value), so
      # with `for` this fires about 10 minutes after the last push. It
      # doesn't name services, so a new one is covered from its first push,
      # and one that's been removed stops alerting after a day.
      expr        = "label_replace(group by (service_name) (present_over_time(process_uptime_milliseconds{${local.production}}[1d])) unless group by (service_name) (process_uptime_milliseconds{${local.production}})${local.as_service}"
      datasource  = data.grafana_data_source.metrics.uid
      test        = "gt"
      threshold   = 0
      for         = "5m"
      no_data     = "OK"
      labels      = {}
      panel       = 19
      summary     = "{{ $labels.service }} has stopped sending metrics"
      description = "Nothing has arrived for about 10 minutes. It's down, or it can't reach Grafana."
    },
    {
      name = "Certificate expiring"
      # Days until the TLS certificate a check was shown runs out.
      # DigitalOcean renews them about a month ahead, so under 14 days means
      # renewal has failed, with two weeks left to fix it.
      expr        = "(min by (job, instance) (probe_ssl_earliest_cert_expiry) - time()) / 86400 * ${local.check_service}"
      datasource  = data.grafana_data_source.metrics.uid
      test        = "lt"
      threshold   = 14
      for         = "0s"
      no_data     = "OK"
      labels      = {}
      panel       = 4
      summary     = "The certificate for {{ $labels.instance }} expires in {{ printf \"%.0f\" $values.B.Value }} days"
      description = "It should have been renewed by now."
    },
    {
      name = "Near the free-tier limit"
      # Active series in the stack, as a percentage of what the free tier
      # allows. Past 100% Grafana drops what doesn't fit.
      expr        = "100 * max(grafanacloud_instance_active_series) / ${local.series_allowance}"
      datasource  = data.grafana_data_source.usage.uid
      test        = "gt"
      threshold   = 80
      for         = "1h"
      no_data     = "NoData"
      labels      = { service = "grafana-cloud" }
      panel       = null
      summary     = "{{ printf \"%.0f\" $values.B.Value }}% of the free tier's ${local.series_allowance} series are in use"
      description = "Above 80% for an hour. Find what grew before Grafana starts dropping data."
    },
  ]
}

# A rule group is a set of rules evaluated together, on one interval. Every
# minute is as often as the data changes: services push once a minute.
resource "grafana_rule_group" "services" {
  provider = grafana.stack

  name             = "services"
  folder_uid       = grafana_folder.services.uid
  interval_seconds = 60

  dynamic "rule" {
    for_each = local.alerts

    content {
      name = rule.value.name
      for  = rule.value.for

      # A rule is a small pipeline, and `condition` names the step whose
      # result decides: A runs the query, B takes each series' latest value,
      # C tests it against the threshold.
      condition = "C"

      no_data_state = rule.value.no_data
      # A query that fails (Grafana can't reach its own database, say) is
      # reported as an alert of its own, not counted as OK or as firing.
      exec_err_state = "Error"

      labels = rule.value.labels

      # Two links to the dashboard. The email shows annotations as plain
      # text, so `dashboard` is only a link if the mail program makes it
      # one, but it opens with the right service picked. The two reserved
      # names are what Grafana turns into the email's dashboard and panel
      # buttons; those open with whichever service the picker defaults to.
      # Grafana wants both of the pair or neither.
      annotations = merge(
        {
          summary     = rule.value.summary
          description = rule.value.description
          dashboard   = "${local.dashboard_url}{{ if $labels.service }}?var-service={{ $labels.service }}{{ end }}"
        },
        rule.value.panel == null ? {} : {
          "__dashboardUid__" = grafana_dashboard.services.uid
          "__panelId__"      = tostring(rule.value.panel)
        },
      )

      data {
        ref_id         = "A"
        datasource_uid = rule.value.datasource

        relative_time_range {
          from = 600
          to   = 0
        }

        # instant: one value per series, as of now, instead of a graph's
        # worth of points.
        model = jsonencode({
          refId         = "A"
          expr          = rule.value.expr
          instant       = true
          range         = false
          intervalMs    = 1000
          maxDataPoints = 43200
        })
      }

      # B and C aren't queries: "__expr__" is Grafana's own calculator,
      # working on the results of the steps before.
      data {
        ref_id         = "B"
        datasource_uid = "__expr__"

        relative_time_range {
          from = 0
          to   = 0
        }

        model = jsonencode({
          refId      = "B"
          type       = "reduce"
          expression = "A"
          reducer    = "last"
        })
      }

      data {
        ref_id         = "C"
        datasource_uid = "__expr__"

        relative_time_range {
          from = 0
          to   = 0
        }

        model = jsonencode({
          refId      = "C"
          type       = "threshold"
          expression = "B"
          conditions = [{
            evaluator = { type = rule.value.test, params = [rule.value.threshold] }
          }]
        })
      }
    }
  }
}

# Where notifications go. The address is a variable (see variables.tf), so
# it's in neither the repo nor a plan. Grafana Cloud sends the email itself:
# there's no mail server to set up. It also sends a "resolved" email when an
# alert stops firing.
resource "grafana_contact_point" "email" {
  provider = grafana.stack

  name = "email"

  email {
    addresses = [var.alert_email]
  }
}

# The policy is a tree of routes; this is the whole tree, a root with no
# branches: everything goes to the one contact point. Grafana has exactly
# one policy, so this resource replaces whatever was there, including routes
# made in the UI.
#
# Grouping is what keeps an outage from being six emails. Alerts with the
# same `service` are sent together, so "accounts is down", "accounts has
# stopped sending metrics" and both of its failing checks arrive as one.
resource "grafana_notification_policy" "main" {
  provider = grafana.stack

  contact_point = grafana_contact_point.email.name
  group_by      = ["service"]

  # After the first alert of a group fires, wait this long for others to
  # join it before sending.
  group_wait = "1m"
  # Then tell us about alerts that join or leave the group at most this often.
  group_interval = "5m"
  # And while nothing changes, remind us this often that it's still firing.
  repeat_interval = "12h"
}
