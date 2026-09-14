# User-assigned managed identities, plus the RBAC role assignments that give
# each one exactly what it needs — Azure's equivalent of the AWS stack's IAM
# roles (iam.tf) and instance-profile-style task credentials, minted through
# azurerm_role_assignment instead of an IAM policy document.
#
# The AWS stack splits ECS into an EXECUTION role (pulls the image, reads
# secrets, writes logs — done on the task's behalf by the platform) and a
# TASK role (what the running container calls on its own behalf — iam.tf's
# own task_api/task_worker, which exist only to grant EFS's IAM-authorized
# mount). Container Apps has no such two-role split to mirror: there is one
# identity per app, used for both registry pull and the native Key Vault
# secret references (containerapps.tf's `secret` blocks), and Azure Files
# mounts (containerapps.tf's environment storage) authenticate with a storage
# account key rather than an identity at all — so there is no Container-Apps
# equivalent of the AWS task role's EFS ClientMount grant to create here. This
# is a genuine platform simplification, not a corner cut: Container Apps'
# identity model really does have one fewer moving part than ECS's.

resource "azurerm_user_assigned_identity" "data_cmk" {
  # Shared by the Storage Account (storage.tf), Postgres Flexible Server
  # (postgres.tf) and ACR (acr.tf) customer_managed_key/encryption blocks —
  # same "one key, one grant-holder set" reasoning as kms.tf's single CMK on
  # the AWS side: none of the three needs a privilege distinct from the
  # others, they all only ever wrap/unwrap under this stack's one data key.
  name                = "${var.name_prefix}-data-cmk"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-data-cmk", Component = "security" })
}

resource "azurerm_role_assignment" "data_cmk_key_vault_crypto_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Crypto Service Encryption User"
  principal_id         = azurerm_user_assigned_identity.data_cmk.principal_id
}

# ---- api/worker: read secrets, pull their own images -------------------------
# Shared by api and worker only — mirrors the AWS stack's own
# aws_iam_role.execution split (iam.tf), which api/worker share and web does
# not.
resource "azurerm_user_assigned_identity" "api_worker" {
  name                = "${var.name_prefix}-api-worker"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-api-worker", Component = "security" })
}

resource "azurerm_role_assignment" "api_worker_key_vault_secrets_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.api_worker.principal_id
}

# Registry-wide AcrPull, not scoped to just the api/worker repositories: the
# AWS stack's own execution role can pull ONLY api's and worker's ECR repos,
# never web's (iam.tf's execution_extra PullOwnImages statement, scoped by
# repository ARN). ACR's equivalent mechanism — repository-scoped RBAC via
# Azure ABAC conditions on the role assignment, surfaced on
# azurerm_container_registry as `role_assignment_mode =
# "AbacRepositoryPermissions"` (acr.tf's own comment) — exists, but this
# stack does not use it: the exact condition-expression syntax and its GA
# maturity could not be verified from within the environment this stack was
# built in, and getting a security boundary wrong by guessing at unverified
# syntax is worse than stating the gap plainly. This is a real, deliberate
# regression from the AWS stack's per-repo IAM scoping, not a hidden one —
# api/worker's identity can pull web's image too, and vice versa, until an
# operator verifies the ABAC condition syntax for their provider version and
# tightens this.
resource "azurerm_role_assignment" "api_worker_acr_pull" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.api_worker.principal_id
}

# ---- web: pulls its own image, reads no secrets -------------------------------
# Mirrors the AWS stack's aws_iam_role.execution_web (iam.tf) — same
# isolation reasoning: web is a static SPA/nginx that reads no DSN, no
# keyvault key, nothing, so it gets no path to any of them.
resource "azurerm_user_assigned_identity" "web" {
  name                = "${var.name_prefix}-web"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-web", Component = "security" })
}

resource "azurerm_role_assignment" "web_acr_pull" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.web.principal_id
}
