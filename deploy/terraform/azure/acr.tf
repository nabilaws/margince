# Premium SKU is this stack's one deliberate cost increase over the cheapest
# option — every other service here defaults to the cheapest SKU that still
# hits the managed-service/security bar (variables.tf's own comments explain
# each one). ACR is the exception because Premium is the ONLY tier that
# supports two things everything else in this stack already has: a private
# endpoint (privateendpoints.tf) and a customer-managed key (below). Basic/
# Standard ACR would make this the one public-endpoint, platform-key
# exception in a stack that private-networks and CMK-encrypts everything
# else — Premium buys back posture consistency, at Premium's own list price.
resource "azurerm_container_registry" "this" {
  name                = "${replace(var.name_prefix, "-", "")}acr"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "Premium"
  admin_enabled       = false

  public_network_access_enabled = false
  # Routes the registry's own underlying blob-layer traffic (image layers,
  # not just the control-plane API) through the private endpoint below too —
  # Premium-only, and specifically documented as needed once a registry sits
  # behind Private Link, or pulls fall back to ACR's regional public data
  # endpoint for the layer bytes even though the control-plane call went
  # private.
  data_endpoint_enabled = true

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.data_cmk.id]
  }

  encryption {
    key_vault_key_id   = azurerm_key_vault_key.data.versionless_id
    identity_client_id = azurerm_user_assigned_identity.data_cmk.client_id
  }

  # Untagged-manifest cleanup only (Premium-only) — mirrors the untagged half
  # of the AWS stack's ECR lifecycle policy (ecs.tf's untagged_expiry_policy,
  # rule 1). ACR has no Terraform-exposed equivalent of that same policy's
  # rule 2 (keep only the N most recent TAGGED/released images): there is no
  # "expire tagged images beyond a count" lifecycle rule on
  # azurerm_container_registry at all, so var.ecr_tagged_image_retain_count's
  # AWS-side reasoning (bound the rollback window, since IMMUTABLE tags never
  # get reclaimed) has nothing to attach to here. Nor is there a Terraform-
  # managed equivalent of ECR's image_tag_mutability = IMMUTABLE at all — ACR
  # tag locking (`az acr repository update --write-enabled false`) is a
  # data-plane operation on an existing tag, invoked through the CLI/REST API
  # against the registry's data plane, not a control-plane setting this
  # resource exposes for Terraform to hold. Both gaps are stated here plainly
  # rather than worked around: an operator wanting AWS-equivalent tag
  # immutability and release-count bounding on ACR today does it by hand,
  # per push, or scripts it outside Terraform.
  #
  # retention_policy (block), not retention_policy_in_days (attribute): the
  # provider's 3.x line still expects the block form — retention_policy_in_days
  # exists in the resource's Go schema only under a future v4.0 build flag
  # this provider release does not set, confirmed against
  # `terraform validate` rejecting it outright at v3.117.1 (versions.tf's own
  # pin). An operator who upgrades this stack's provider constraint to
  # azurerm 4.x needs to swap this block for that attribute.
  retention_policy {
    enabled = true
    days    = var.acr_untagged_manifest_retention_days
  }

  # Not enabled: quarantine_policy_enabled predates and has been superseded by
  # Microsoft Defender for Cloud's own native container image scanning
  # integration, which is a subscription-level Defender plan setting, not a
  # property of this resource — out of scope for this stack the same way
  # GuardDuty is out of scope on the AWS side (see azure/README.md's
  # "Deliberately not done").

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-acr", Component = "container-registry" })

  depends_on = [azurerm_role_assignment.data_cmk_key_vault_crypto_user]
}
