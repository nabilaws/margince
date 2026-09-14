# alarms.tf's own AWS-side comment watches CPUCreditBalance on both burstable
# (T-family) resources that stack defaults to — Azure has no direct mirror of
# that metric for either service this stack provisions:
#   - Postgres Flexible Server's Burstable SKU (postgres.tf's B_Standard_B2s)
#     bills and throttles on the underlying B-series VM's CPU credit
#     mechanism the same way EC2/RDS T-family does, but Azure Monitor does
#     not surface a credit-balance metric for this PaaS resource the way it
#     does for an IaaS VM directly — Postgres Flexible Server's own metric
#     catalog stops at cpu_percent, memory_percent, storage_percent,
#     active_connections and the like. cpu_percent sustained high is the
#     closest available proxy for "about to throttle" this resource exposes,
#     not a literal credit-balance reading.
#   - Azure Cache for Redis's C-family (Basic/Standard) SKU tier is NOT
#     burstable compute at all, unlike ElastiCache's own cache.t4g.small —
#     there is no credit mechanism to watch here because none exists for
#     this tier. serverLoad (Azure's own documented saturation metric for
#     this resource — sustained high values are Microsoft's own
#     documented signal that the cache is falling behind) is the closest
#     real equivalent to "this is about to get slow", watched for the same
#     "catch it before an application-side timeout does" reason
#     alarms.tf's AWS-side comment gives.
#
# No subscription wired beyond the optional var.alert_email — an operator's
# alert destination is theirs to own, same reasoning as the AWS stack.
#
# Every resource below is gated on var.enable_deep_monitoring (variables.tf),
# so this whole file is a no-op when it's false, mirroring the AWS stack's
# alarms.tf.

resource "azurerm_monitor_action_group" "alerts" {
  count               = var.enable_deep_monitoring ? 1 : 0
  name                = "${var.name_prefix}-alerts"
  resource_group_name = azurerm_resource_group.this.name
  short_name          = substr(var.name_prefix, 0, 12)

  dynamic "email_receiver" {
    for_each = var.alert_email != "" ? [var.alert_email] : []
    content {
      name          = "operator"
      email_address = email_receiver.value
    }
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-alerts", Component = "observability" })
}

resource "azurerm_monitor_metric_alert" "postgres_cpu" {
  count               = var.enable_deep_monitoring ? 1 : 0
  name                = "${var.name_prefix}-postgres-cpu-high"
  resource_group_name = azurerm_resource_group.this.name
  scopes              = [azurerm_postgresql_flexible_server.this.id]
  description         = "Postgres Flexible Server ${azurerm_postgresql_flexible_server.this.name} is sustaining high CPU — on a Burstable SKU this is the closest available signal that it is about to throttle, since this resource exposes no credit-balance metric directly (see this file's own top comment)."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.DBforPostgreSQL/flexibleServers"
    metric_name      = "cpu_percent"
    aggregation      = "Average"
    operator         = "GreaterThan"
    # A starting point, not a tuned value — the same honest-floor reasoning
    # alarms.tf's AWS-side threshold gives for its own 20-credit floor.
    threshold = 80
  }

  action {
    action_group_id = azurerm_monitor_action_group.alerts[0].id
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-postgres-cpu-high", Component = "observability" })
}

resource "azurerm_monitor_metric_alert" "redis_server_load" {
  count               = var.enable_deep_monitoring ? 1 : 0
  name                = "${var.name_prefix}-redis-server-load-high"
  resource_group_name = azurerm_resource_group.this.name
  scopes              = [azurerm_redis_cache.this.id]
  description         = "Redis ${azurerm_redis_cache.this.name}'s serverLoad is sustaining high — this resource's own documented saturation signal, and the closest equivalent this stack has to alarms.tf's AWS-side ElastiCache CPU-credit alarm (this tier is not burstable compute at all; see this file's own top comment)."
  severity            = 2
  frequency           = "PT5M"
  window_size         = "PT15M"

  criteria {
    metric_namespace = "Microsoft.Cache/redis"
    metric_name      = "serverLoad"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 80
  }

  action {
    action_group_id = azurerm_monitor_action_group.alerts[0].id
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-redis-server-load-high", Component = "observability" })
}
