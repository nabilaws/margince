# One customer-managed key for everything this stack stores at rest: the
# blobstore/config Storage Account, Postgres Flexible Server, and ACR (all
# three's own customer_managed_key/encryption block references
# azurerm_key_vault_key.data below) — same "one key, not N, because the
# blast-radius boundary is already the per-consumer RBAC grants below" reasoning
# as the AWS stack's kms.tf. Redis is the one CMK-eligible-elsewhere service
# NOT wired to this key — see redis.tf's own comment for why Premium-only CMK
# support makes that a deliberate, documented gap rather than an oversight.
#
# rbac_authorization_enabled = true (not vault access policies): every other
# access control in this stack (ACR, Storage, Postgres, Container Apps) is
# already Azure RBAC role assignments (identity.tf) — access policies would be
# a second, parallel permission model to keep in step with it.
#
# purge_protection_enabled = true + soft_delete_retention_days = 90 (the
# maximum): mirrors kms.tf's 30-day KMS deletion window's intent — a deleted
# key/vault is recoverable, not gone, for a bounded window; the AWS stack picks
# a window it can shorten later, this stack picks Azure's own ceiling because
# once purge protection is enabled here it can never be disabled again (the
# resource's own documented, permanent constraint — see versions.tf's
# provider `features` block, which turns off Terraform's own destroy-time
# purge to match).
resource "azurerm_key_vault" "this" {
  name                       = "${var.name_prefix}-kv"
  location                   = azurerm_resource_group.this.location
  resource_group_name        = azurerm_resource_group.this.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "premium" # premium: HSM-backed keys, required for the CMK key type below
  enable_rbac_authorization  = true
  purge_protection_enabled   = true
  soft_delete_retention_days = 90
  # Public endpoint only while operator_ip_allowlist is set (setup, laptop
  # access); default-deny below lets in nothing else.
  public_network_access_enabled = length(var.operator_ip_allowlist) > 0

  network_acls {
    # AzureServices bypass, not None: Storage/Postgres/ACR's own
    # customer_managed_key wiring calls Key Vault AS a trusted Azure service on
    # the consuming resource's behalf, over Azure's private backbone — not
    # through this stack's own private endpoint (privateendpoints.tf's own
    # Key Vault entry is for THIS stack's operators/Container Apps reading
    # secrets, a different caller than the CMK-consuming services themselves).
    bypass         = "AzureServices"
    default_action = "Deny"
    ip_rules       = var.operator_ip_allowlist
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-kv", Component = "security" })
}

# RBAC-authorization mode delegates EVERY data-plane action — including
# creating the key and secrets below — to Azure RBAC, with no default grant
# to whoever is running `terraform apply` itself (unlike the legacy
# access-policy model, which the resource above deliberately does not use).
# Without this, every azurerm_key_vault_key/azurerm_key_vault_secret resource
# in this stack fails Forbidden the moment it tries to write. Role
# assignments can take a short time to propagate — a fresh `terraform apply`
# immediately after this grant lands may need one retry.
resource "azurerm_role_assignment" "terraform_key_vault_administrator" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_key_vault_key" "data" {
  name         = "${var.name_prefix}-data"
  key_vault_id = azurerm_key_vault.this.id
  # RSA, not EC: every consumer of this key (Storage Account, Postgres
  # Flexible Server, ACR customer_managed_key/encryption blocks) requires an
  # RSA key for envelope encryption — none of them accept an EC key.
  key_type = "RSA"
  key_size = 2048

  key_opts = [
    "decrypt",
    "encrypt",
    "sign",
    "unwrapKey",
    "verify",
    "wrapKey",
  ]

  rotation_policy {
    expire_after         = "P2Y"
    notify_before_expiry = "P30D"
    automatic {
      time_before_expiry = "P30D"
    }
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-data", Component = "security" })

  depends_on = [azurerm_role_assignment.terraform_key_vault_administrator]
}
