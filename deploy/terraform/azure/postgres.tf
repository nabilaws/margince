# The Flexible Server's own admin login is a THIRD credential, distinct from
# the two DB roles scripts/deploy/db-bootstrap.sql creates (margince_owner,
# margince_app — see docs/deployment.md's "two-role database model"). Named
# "pgadmin" rather than "margince_owner", same reasoning as the AWS stack's
# rds.tf: never confused with the role the bootstrap script creates. Azure
# Postgres Flexible Server's admin is granted a broad, non-superuser
# privilege set (create role, create database, manage allow-listed
# extensions) — the platform's own replacement for a true superuser, in
# effect analogous to RDS's rds_superuser. This analogy is stated here on the
# strength of Azure's own documented admin capabilities, not a live-tested
# confirmation from within the environment this stack was built in — verify
# it against the actual server before relying on it for anything security-
# critical beyond what azure/README.md's bootstrap section walks through.
resource "random_password" "postgres_admin" {
  length  = 32
  special = false
}

resource "random_password" "margince_owner" {
  length  = 32
  special = false
}

resource "random_password" "margince_app" {
  length  = 32
  special = false
}

# ---- Private connectivity: delegated subnet, not a private endpoint ---------
# Postgres Flexible Server's own official example (azurerm's provider docs)
# demonstrates VNet-integrated connectivity via a delegated subnet + private
# DNS zone, not a private endpoint attached after the fact — private-endpoint
# connectivity for Flexible Server also exists, but only in the server's
# separate "public access with private endpoint" networking mode, a less
# common and more constrained path than the VNet-integrated mode shown as
# standard. This stack uses the delegated-subnet path (network.tf's
# azurerm_subnet.postgres) for that reason, which is a deviation from the
# private-endpoint-for-everything framing an operator might expect given
# every OTHER data service in this stack sits behind one — Postgres is the
# one exception, and the exception is the provider's own documented default,
# not an inconsistency introduced here.
resource "azurerm_private_dns_zone" "postgres" {
  name                = "${var.name_prefix}.postgres.database.azure.com"
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-postgres", Component = "database" })
}

resource "azurerm_private_dns_zone_virtual_network_link" "postgres" {
  name                  = "${var.name_prefix}-postgres"
  private_dns_zone_name = azurerm_private_dns_zone.postgres.name
  resource_group_name   = azurerm_resource_group.this.name
  virtual_network_id    = azurerm_virtual_network.this.id
}

resource "azurerm_postgresql_flexible_server" "this" {
  name                = "${var.name_prefix}-db"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  version             = var.db_version

  delegated_subnet_id = azurerm_subnet.postgres.id
  private_dns_zone_id = azurerm_private_dns_zone.postgres.id

  administrator_login    = "pgadmin"
  administrator_password = random_password.postgres_admin.result
  authentication {
    password_auth_enabled = true
  }

  sku_name     = var.db_sku_name
  storage_mb   = var.db_storage_mb
  storage_tier = "P6"

  backup_retention_days = var.db_backup_retention_days
  # Single-region only, matching the AWS stack's own scope (no multi-region/DR
  # — see the shared README's "What this does NOT cover"). Geo-redundant
  # backup is Azure's own knob for that and costs more; left off for the same
  # reason.
  geo_redundant_backup_enabled = false

  dynamic "high_availability" {
    for_each = var.db_zone_redundant_ha ? [1] : []
    content {
      mode = "ZoneRedundant"
    }
  }

  maintenance_window {
    day_of_week  = 1 # Monday, matching the AWS stack's own mon:04:30 window
    start_hour   = 4
    start_minute = 30
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.data_cmk.id]
  }

  customer_managed_key {
    key_vault_key_id                  = azurerm_key_vault_key.data.versionless_id
    primary_user_assigned_identity_id = azurerm_user_assigned_identity.data_cmk.id
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-db", Component = "database" })

  depends_on = [
    azurerm_private_dns_zone_virtual_network_link.postgres,
    azurerm_role_assignment.data_cmk_key_vault_crypto_user,
  ]

  # No final_snapshot_identifier / random_id keepers to mirror from the AWS
  # stack's rds.tf: Postgres Flexible Server does not require (or accept) a
  # named final snapshot on delete — deletion is covered by
  # backup_retention_days' own point-in-time-restore window instead, so the
  # AWS stack's finalizer-name collision problem (a second delete reusing a
  # name the first delete's snapshot still holds) does not exist on this
  # platform to work around.
  #
  # scripts/deploy/db-bootstrap.sql runs once, by hand, against this server as
  # "pgadmin" (see azure/README.md) — UNLIKE the AWS path, the "margince"
  # database does NOT already exist here (Flexible Server only ever
  # provisions a default "postgres" database, with no db_name-equivalent
  # argument to create another one at provision time), so the script's own
  # `CREATE DATABASE margince OWNER margince_owner` branch actually runs here,
  # rather than being skipped the way it is on RDS.
}

# Allow-lists the extensions migration 0001_baseline installs
# (db-bootstrap.sql) — Postgres Flexible Server refuses `CREATE EXTENSION`,
# even for the admin login, for any extension not named in this server-level
# setting first. There is no SQL-side equivalent of this on Azure: RDS lets a
# superuser-equivalent role install an allow-listed extension directly
# (rds.tf's own comment), Azure additionally requires the allow-list itself
# to be granted through the control plane (this resource) before
# db-bootstrap.sql's CREATE EXTENSION statements can succeed at all. Getting
# the apply order backwards here — bootstrapping the database before this
# configuration lands — fails at the vector extension with an error naming
# the extension, not a Terraform error, so depends_on makes the ordering
# explicit rather than incidental.
resource "azurerm_postgresql_flexible_server_configuration" "azure_extensions" {
  name      = "azure.extensions"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "VECTOR,UNACCENT,PG_TRGM,BTREE_GIST"
}

# Server refuses a plaintext connection outright — this is the Azure
# equivalent of the AWS stack's rds.force_ssl parameter (rds.tf), and the
# same server-side backstop reasoning: sslmode=require alone only asks the
# CLIENT to encrypt, this makes the SERVER refuse a client that doesn't.
resource "azurerm_postgresql_flexible_server_configuration" "require_secure_transport" {
  name      = "require_secure_transport"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "ON"
}

# None of these four log_* GUCs default to on — without them the log export
# below (azurerm_monitor_diagnostic_setting's PostgreSQLLogs category) ships
# an empty stream, mirroring the AWS stack's own rds.tf parameter group
# comment exactly.
resource "azurerm_postgresql_flexible_server_configuration" "log_min_duration_statement" {
  name      = "log_min_duration_statement"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "1000"
}

resource "azurerm_postgresql_flexible_server_configuration" "log_connections" {
  name      = "log_connections"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "on"
}

resource "azurerm_postgresql_flexible_server_configuration" "log_disconnections" {
  name      = "log_disconnections"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "on"
}

resource "azurerm_postgresql_flexible_server_configuration" "log_lock_waits" {
  name      = "log_lock_waits"
  server_id = azurerm_postgresql_flexible_server.this.id
  value     = "on"
}

# Query/instance-level visibility is platform-integrated on Azure — unlike
# the AWS stack, which needs its own IAM role for RDS Enhanced Monitoring
# (rds.tf's aws_iam_role.rds_enhanced_monitoring) because a separate AWS
# service publishes those metrics on the instance's behalf, Azure Monitor
# already collects Postgres Flexible Server's own metrics (cpu_percent,
# memory_percent, storage_percent, active_connections, …) with no IAM
# plumbing to wire up — this diagnostic setting ships the LOG side
# (postgresql.log-equivalent) to the same Log Analytics workspace every other
# resource in this stack uses (network.tf).
resource "azurerm_monitor_diagnostic_setting" "postgres" {
  name                       = "${var.name_prefix}-db"
  target_resource_id         = azurerm_postgresql_flexible_server.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category = "PostgreSQLLogs"
  }

  metric {
    category = "AllMetrics"
  }
}
