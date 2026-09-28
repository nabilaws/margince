# ---------------------------------------------------------------------------
# Attachments: the product's object-store client
# (backend/internal/platform/blobstore/s3.go) speaks the S3 API only, and
# Azure Blob Storage does not. Until an Azure Blob adapter exists, Margince
# stores attachments with its FILESYSTEM provider (blobstore/fs.go) on the
# attachments Azure Files share below, mounted read-write at /app/blobstore in
# api and worker (MARGINCE_BLOBSTORE_PATH, containerapps.tf). The blob
# container stays provisioned but unused, ready for that adapter.
#
# To verify on first deploy: the filesystem store renames and syncs files;
# Azure Files over SMB supports both, but upload one attachment and read it
# back before relying on it.
# ---------------------------------------------------------------------------

# One storage account for both the blobstore container and the Container
# Apps config file share (storage.tf's azurerm_storage_share.config, below)
# — StorageV2 supports Blob and File in the same account, both mounts are
# read by the same api/worker roles, and both want the same CMK/private
# endpoint already justified once rather than twice. The tradeoff: a lifecycle
# rule scoped to blob types only (this account's management policy, below)
# does not reach the file share — files.core has no equivalent
# Terraform-managed lifecycle policy resource at all, so that share is
# operator-managed once written, same as the AWS stack's EFS config mount.
resource "azurerm_storage_account" "this" {
  name                = "${replace(var.name_prefix, "-", "")}data"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  account_kind = "StorageV2"
  account_tier = "Standard"
  # Zone-redundant, not locally-redundant: this stack already commits to
  # zone-redundant HA everywhere else it can (postgres.tf's ZoneRedundant
  # mode, the zone-redundant Container Apps environment) — LRS would make the CRM's one attachment
  # store the single tier-level exception to that posture. Not GRS/geo
  # redundant: this stack is single-region by design (the shared README's
  # "What this does NOT cover" — no multi-region/HA), so paying for
  # cross-region replication here would buy a DR posture the rest of the
  # stack does not have either.
  account_replication_type = "ZRS"

  min_tls_version = "TLS1_2"
  # Public endpoint only while operator_ip_allowlist is set; the network rules
  # below still deny everyone else. Container Apps reach the shares through
  # the private endpoint either way.
  public_network_access_enabled   = length(var.operator_ip_allowlist) > 0
  allow_nested_items_to_be_public = false

  network_rules {
    default_action = "Deny"
    bypass         = ["AzureServices"]
    ip_rules       = var.operator_ip_allowlist
  }

  blob_properties {
    versioning_enabled = true

    # 30 days: an accidental delete/overwrite is recoverable without keeping
    # a soft-deleted blob forever — the container-level rule below covers a
    # deleted CONTAINER the same way.
    delete_retention_policy {
      days = 30
    }
    container_delete_retention_policy {
      days = 30
    }
  }

  # Same identity/key pattern as postgres.tf and acr.tf's own
  # customer_managed_key blocks — one shared data key (keyvault.tf), one
  # shared grant-holder identity (identity.tf's data_cmk).
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.data_cmk.id]
  }

  customer_managed_key {
    key_vault_key_id          = azurerm_key_vault_key.data.versionless_id
    user_assigned_identity_id = azurerm_user_assigned_identity.data_cmk.id
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-data", Component = "storage" })

  depends_on = [azurerm_role_assignment.data_cmk_key_vault_crypto_user]
}

resource "azurerm_storage_container" "blobstore" {
  name                  = "blobstore"
  storage_account_name  = azurerm_storage_account.this.name
  container_access_type = "private"
}

# Mirrors s3.tf's own two lifecycle rules as closely as Azure's blob lifecycle
# management policy allows:
#   - "expire-noncurrent-versions" (s3.tf) -> version.delete after 90 days,
#     the direct equivalent (versioning_enabled above is what makes a
#     "version" exist to expire at all).
#   - s3.tf's "abort-incomplete-multipart-uploads" has NO Azure equivalent
#     rule at all — Azure blob lifecycle management has no
#     action for an uncommitted block list the way S3's
#     abort_incomplete_multipart_upload does; an interrupted large upload's
#     uncommitted blocks are already garbage-collected by the service on its
#     own schedule (Azure's own documented behavior for uncommitted blocks,
#     not a policy this account can tune), so there is nothing to add here to
#     port that rule — the gap only exists because Azure closes it a
#     different way, not because this policy is missing a rule AWS has.
resource "azurerm_storage_management_policy" "this" {
  storage_account_id = azurerm_storage_account.this.id

  rule {
    name    = "expire-noncurrent-versions"
    enabled = true

    filters {
      blob_types = ["blockBlob"]
    }

    actions {
      version {
        delete_after_days_since_creation = 90
      }
    }
  }
}

# Mirrors efs.tf's config mount: read-only margince.yaml, provisioned here,
# written once by hand (azure/README.md's own one-time step) — not by
# Terraform. 5 GiB is Azure Files' own minimum share quota; a config file
# needs a fraction of that, but there is no smaller unit to request.
resource "azurerm_storage_share" "config" {
  name                 = "${var.name_prefix}-config"
  storage_account_name = azurerm_storage_account.this.name
  quota                = 5
}

# Margince's filesystem attachment store (MARGINCE_BLOBSTORE_PATH), mounted
# read-write into api and worker (containerapps.tf). The app's native store
# speaks S3 only, so until an Azure Blob adapter exists this share is where
# attachments live; the blob container above stays unused.
resource "azurerm_storage_share" "attachments" {
  name                 = "${var.name_prefix}-attachments"
  storage_account_name = azurerm_storage_account.this.name
  quota                = var.attachments_share_quota_gb
}
