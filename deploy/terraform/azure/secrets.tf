# One Key Vault secret per credential, mirroring the AWS stack's own
# secrets.tf shape exactly ("One Secrets Manager secret per credential") minus
# the two blobstore IAM-user credentials that file also carries — this stack
# has no blobstore adapter yet (storage.tf's own top comment), so there is no
# access key/secret pair here to seal. Every secret is created under this
# stack's Key Vault (keyvault.tf), whose own encryption-at-rest is Microsoft-
# managed by default; Key Vault itself has no customer_managed_key concept to
# wire to keyvault.tf's data key — CMK on a vault's OWN storage is not a
# capability Azure Key Vault exposes at all, unlike a consumer of that key.

resource "random_id" "keyvault_root_key" {
  byte_length = 32
}

resource "random_id" "webhook_key" {
  byte_length = 32
}

resource "random_id" "connector_state_key" {
  byte_length = 32
}

locals {
  # Azure Postgres Flexible Server's TLS certificate chains to DigiCert Global
  # Root G2/CA, a public root most client trust stores already carry — unlike
  # the AWS stack's own RDS CA bundle (secrets.tf there), which is
  # AWS-private and has to be downloaded and mounted onto the config volume
  # by hand (aws/README.md step 4) before sslmode=verify-full can succeed.
  # verify-full here needs no sslrootcert param for that reason — a genuine
  # simplification versus the AWS path, not a gap in this one.
  db_host   = azurerm_postgresql_flexible_server.this.fqdn
  owner_dsn = "postgres://margince_owner:${urlencode(random_password.margince_owner.result)}@${local.db_host}:5432/margince?sslmode=verify-full"
  app_dsn   = "postgres://margince_app:${urlencode(random_password.margince_app.result)}@${local.db_host}:5432/margince?sslmode=verify-full"
}

resource "azurerm_key_vault_secret" "owner_dsn" {
  name         = "margince-owner-dsn"
  value        = local.owner_dsn
  key_vault_id = azurerm_key_vault.this.id
  tags         = merge(local.common_tags, { Name = "${var.name_prefix}-owner-dsn", Component = "secrets" })

  depends_on = [azurerm_role_assignment.terraform_key_vault_administrator]
}

resource "azurerm_key_vault_secret" "app_dsn" {
  name         = "margince-dsn"
  value        = local.app_dsn
  key_vault_id = azurerm_key_vault.this.id
  tags         = merge(local.common_tags, { Name = "${var.name_prefix}-app-dsn", Component = "secrets" })

  depends_on = [azurerm_role_assignment.terraform_key_vault_administrator]
}

resource "azurerm_key_vault_secret" "redis_password" {
  name         = "margince-redis-password"
  value        = azurerm_redis_cache.this.primary_access_key
  key_vault_id = azurerm_key_vault.this.id
  tags         = merge(local.common_tags, { Name = "${var.name_prefix}-redis-password", Component = "secrets" })

  depends_on = [azurerm_role_assignment.terraform_key_vault_administrator]
}

resource "azurerm_key_vault_secret" "keyvault_root_key" {
  name         = "margince-keyvault-root-key"
  value        = random_id.keyvault_root_key.b64_std
  key_vault_id = azurerm_key_vault.this.id
  tags         = merge(local.common_tags, { Name = "${var.name_prefix}-keyvault-root-key", Component = "secrets" })

  depends_on = [azurerm_role_assignment.terraform_key_vault_administrator]
}

resource "azurerm_key_vault_secret" "webhook_key" {
  name         = "margince-webhook-key"
  value        = random_id.webhook_key.b64_std
  key_vault_id = azurerm_key_vault.this.id
  tags         = merge(local.common_tags, { Name = "${var.name_prefix}-webhook-key", Component = "secrets" })

  depends_on = [azurerm_role_assignment.terraform_key_vault_administrator]
}

resource "azurerm_key_vault_secret" "connector_state_key" {
  name         = "margince-connector-state-key"
  value        = random_id.connector_state_key.b64_std
  key_vault_id = azurerm_key_vault.this.id
  tags         = merge(local.common_tags, { Name = "${var.name_prefix}-connector-state-key", Component = "secrets" })

  depends_on = [azurerm_role_assignment.terraform_key_vault_administrator]
}

resource "azurerm_key_vault_secret" "admin_password" {
  name         = "margince-admin-password"
  value        = var.admin_bootstrap_password
  key_vault_id = azurerm_key_vault.this.id
  tags         = merge(local.common_tags, { Name = "${var.name_prefix}-admin-password", Component = "secrets" })

  depends_on = [azurerm_role_assignment.terraform_key_vault_administrator]
}

# Created unconditionally so containerapps.tf's secret block always has a
# key_vault_secret_id to point at — an empty string is a valid MARGINCE_LICENSE
# (runs unlicensed; only a production role without MARGINCE_ENV set refuses to
# boot on that), same as the AWS stack's own license secret.
resource "azurerm_key_vault_secret" "license" {
  name         = "margince-license"
  value        = var.license_token
  key_vault_id = azurerm_key_vault.this.id
  tags         = merge(local.common_tags, { Name = "${var.name_prefix}-license", Component = "secrets" })

  depends_on = [azurerm_role_assignment.terraform_key_vault_administrator]
}

# The Entra app's client secret (entra.tf), read by api and worker as
# MARGINCE_GRAPH_CLIENT_SECRET: Margince's Microsoft sign-in and its Graph
# mail/calendar connectors share this one credential (cmd/api/microsoftsignin.go).
resource "azurerm_key_vault_secret" "entra_client_secret" {
  name         = "margince-entra-client-secret"
  value        = local.entra_client_secret
  key_vault_id = azurerm_key_vault.this.id
  tags         = merge(local.common_tags, { Name = "${var.name_prefix}-entra-client-secret", Component = "secrets" })

  depends_on = [azurerm_role_assignment.terraform_key_vault_administrator]
}
