# Standard, not Basic: see variables.tf's own comment on redis_sku_name for why
# ("Basic has no replica and no SLA at all") — the AWS stack's own
# aws_elasticache_replication_group.this sets automatic_failover_enabled = true
# and multi_az_enabled = true (elasticache.tf), i.e. it never runs without a
# standby node either, and Standard's built-in primary+replica pair is the
# direct Azure equivalent of that same posture. Premium is NOT picked instead:
# its extra capabilities (VNet injection, a customer-managed key — see the
# comment on customer_managed_key below) cost roughly 10x for this workload's
# actual need, which is failover, not those two extras.
resource "azurerm_redis_cache" "this" {
  name                = "${var.name_prefix}-redis"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  # "C" family (Basic/Standard) with capacity 1 is C1 (1 GiB) — the smallest
  # Standard size, and the closest match to the AWS stack's own
  # cache.t4g.small (elasticache.tf) that a managed-tier SKU (rather than a
  # sized VM) offers.
  sku_name = var.redis_sku_name
  family   = "C"
  capacity = var.redis_capacity

  # TLS-only: refuses any client that doesn't negotiate TLS, the same
  # server-side backstop reasoning as postgres.tf's require_secure_transport
  # and the AWS stack's own transit_encryption_mode = "required"
  # (elasticache.tf). Unlike the AWS stack's own history with that setting
  # (elasticache.tf's comment on why it once had to stay "preferred" until the
  # app's Redis client gained TLS support), this stack starts at the strict
  # setting from day one — no non-TLS deployment of this app ever ran against
  # it to migrate away from.
  minimum_tls_version           = "1.2"
  enable_non_ssl_port           = false
  public_network_access_enabled = false

  redis_configuration {
    # Same reasoning as elasticache.tf's own maxmemory-policy: this replication
    # group is an outbox relay, where a dropped key under memory pressure is a
    # lost event, not a recoverable cache miss. noeviction/OOM is the loud
    # failure this stack wants in that case, not a silent one.
    maxmemory_policy = "noeviction"
  }

  # Monday-morning maintenance, matching postgres.tf's own window (same
  # reasoning: pick a low-traffic slot once, apply it everywhere in this
  # stack rather than defaulting to whatever Azure's own default rotation
  # picks).
  patch_schedule {
    day_of_week    = "Monday"
    start_hour_utc = 4
  }

  # No customer_managed_key block: Azure Cache for Redis CMK-at-rest support
  # is Premium-tier only (Microsoft's own documented limitation on this
  # resource) — every OTHER data service in this stack (Postgres, Storage,
  # ACR) shares the one CMK in keyvault.tf/identity.tf, and Redis is the one
  # deliberate, documented exception rather than an oversight. Redis still
  # gets Microsoft-managed encryption at rest (the platform default, always
  # on, no opt-out) — what's missing here specifically is the CUSTOMER key,
  # not encryption itself. An operator who needs CMK-at-rest on Redis
  # specifically has to move this one resource to Premium; nothing else in
  # this stack forces that tier choice.
  tags = merge(local.common_tags, { Name = "${var.name_prefix}-redis", Component = "cache" })
}

resource "azurerm_monitor_diagnostic_setting" "redis" {
  name                       = "${var.name_prefix}-redis"
  target_resource_id         = azurerm_redis_cache.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  # ConnectedClientList is the one log category this resource exposes — there
  # is no slow-log-equivalent category to mirror from elasticache.tf's own
  # log_delivery_configuration (Azure Cache for Redis has no Terraform-exposed
  # slow-log export the way ElastiCache does); AllMetrics covers the
  # cpu/memory/serverLoad/connectedclients signal instead (alarms.tf's own
  # server_load alert reads from this same metric stream).
  enabled_log {
    category = "ConnectedClientList"
  }

  metric {
    category = "AllMetrics"
  }
}
