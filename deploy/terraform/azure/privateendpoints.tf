# Every resource this file targets already sets public_network_access_enabled
# = false (keyvault.tf, acr.tf, storage.tf) or is referenced by name from
# those files' own comments as reachable "through this stack's own private
# endpoint" (keyvault.tf, acr.tf, network.tf's azurerm_subnet.private_endpoints
# comment) — this file is that private endpoint set, completing what those
# comments already promised rather than introducing a new design decision.
# Without it, Container Apps has no path to a Key Vault or an ACR that both
# refuse the public internet outright.
#
# One shared subnet (network.tf's azurerm_subnet.private_endpoints), one
# private DNS zone per service, each zone linked to this stack's one VNet —
# the same "one boundary, not N" reasoning network.tf's own comment gives for
# why that subnet isn't split further.

resource "azurerm_private_dns_zone" "key_vault" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-kv", Component = "network" })
}

resource "azurerm_private_dns_zone_virtual_network_link" "key_vault" {
  name                  = "${var.name_prefix}-kv"
  private_dns_zone_name = azurerm_private_dns_zone.key_vault.name
  resource_group_name   = azurerm_resource_group.this.name
  virtual_network_id    = azurerm_virtual_network.this.id
}

resource "azurerm_private_endpoint" "key_vault" {
  name                = "${var.name_prefix}-kv"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-kv", Component = "network" })

  private_service_connection {
    name                           = "${var.name_prefix}-kv"
    private_connection_resource_id = azurerm_key_vault.this.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "kv"
    private_dns_zone_ids = [azurerm_private_dns_zone.key_vault.id]
  }
}

resource "azurerm_private_dns_zone" "acr" {
  name                = "privatelink.azurecr.io"
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-acr", Component = "network" })
}

resource "azurerm_private_dns_zone_virtual_network_link" "acr" {
  name                  = "${var.name_prefix}-acr"
  private_dns_zone_name = azurerm_private_dns_zone.acr.name
  resource_group_name   = azurerm_resource_group.this.name
  virtual_network_id    = azurerm_virtual_network.this.id
}

resource "azurerm_private_endpoint" "acr" {
  name                = "${var.name_prefix}-acr"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-acr", Component = "network" })

  private_service_connection {
    name                           = "${var.name_prefix}-acr"
    private_connection_resource_id = azurerm_container_registry.this.id
    subresource_names              = ["registry"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "acr"
    private_dns_zone_ids = [azurerm_private_dns_zone.acr.id]
  }
}

# One private endpoint for both blob and file sub-resources of the same
# storage account (storage.tf) — Azure documents this combination as
# supported on a single endpoint, unlike, say, blob+queue which need separate
# endpoints for unrelated reasons. Two DNS zones still apply (each
# sub-resource resolves through its own privatelink zone), so both are linked
# in the one private_dns_zone_group below.
resource "azurerm_private_dns_zone" "storage_blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-blob", Component = "network" })
}

resource "azurerm_private_dns_zone_virtual_network_link" "storage_blob" {
  name                  = "${var.name_prefix}-blob"
  private_dns_zone_name = azurerm_private_dns_zone.storage_blob.name
  resource_group_name   = azurerm_resource_group.this.name
  virtual_network_id    = azurerm_virtual_network.this.id
}

resource "azurerm_private_dns_zone" "storage_file" {
  name                = "privatelink.file.core.windows.net"
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-file", Component = "network" })
}

resource "azurerm_private_dns_zone_virtual_network_link" "storage_file" {
  name                  = "${var.name_prefix}-file"
  private_dns_zone_name = azurerm_private_dns_zone.storage_file.name
  resource_group_name   = azurerm_resource_group.this.name
  virtual_network_id    = azurerm_virtual_network.this.id
}

resource "azurerm_private_endpoint" "storage" {
  name                = "${var.name_prefix}-storage"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-storage", Component = "network" })

  private_service_connection {
    name                           = "${var.name_prefix}-storage"
    private_connection_resource_id = azurerm_storage_account.this.id
    subresource_names              = ["blob", "file"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "storage"
    private_dns_zone_ids = [
      azurerm_private_dns_zone.storage_blob.id,
      azurerm_private_dns_zone.storage_file.id,
    ]
  }
}

# Standard-tier Azure Cache for Redis supports Private Link (Premium is not
# required for this one, unlike the CMK gap redis.tf's own comment documents)
# — network.tf's own private_endpoints NSG already carries the
# AllowRedisFromContainerApps rule on 6380 this endpoint answers on.
resource "azurerm_private_dns_zone" "redis" {
  name                = "privatelink.redis.cache.windows.net"
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-redis", Component = "network" })
}

resource "azurerm_private_dns_zone_virtual_network_link" "redis" {
  name                  = "${var.name_prefix}-redis"
  private_dns_zone_name = azurerm_private_dns_zone.redis.name
  resource_group_name   = azurerm_resource_group.this.name
  virtual_network_id    = azurerm_virtual_network.this.id
}

resource "azurerm_private_endpoint" "redis" {
  name                = "${var.name_prefix}-redis"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-redis", Component = "network" })

  private_service_connection {
    name                           = "${var.name_prefix}-redis"
    private_connection_resource_id = azurerm_redis_cache.this.id
    subresource_names              = ["redisCache"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "redis"
    private_dns_zone_ids = [azurerm_private_dns_zone.redis.id]
  }
}
