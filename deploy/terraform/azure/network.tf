data "azurerm_client_config" "current" {}

# azurerm has no provider-level default_tags block the way the aws provider
# does (versions.tf) — every resource below merges this map into its own tags
# instead, so Project/ManagedBy/Environment land everywhere the AWS stack's
# provider default_tags would have put them.
locals {
  common_tags = {
    Project     = "margince"
    ManagedBy   = "terraform"
    Environment = var.environment
  }
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.azure_region
  tags     = local.common_tags
}

resource "azurerm_virtual_network" "this" {
  name                = "${var.name_prefix}-vnet"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [var.vnet_cidr]
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-vnet" })
}

# ---- Subnets -----------------------------------------------------------------
# Azure subnets are regional, not zone-scoped — unlike the AWS stack's
# public/private subnet PER AVAILABILITY ZONE (network.tf there), one subnet
# per TIER already covers every zone; only the resources placed in a subnet
# are individually zone-pinned (postgres.tf's zone, containerapps.tf's
# zone_redundancy_enabled). Three tiers, matching the
# AWS stack's five security groups minus the one (efs) that has no Azure
# equivalent tier of its own — see privateendpoints.tf's own comment on why
# the config-volume share shares the storage-private-endpoints subnet instead
# of getting one of its own.

# cidrsubnet(var.vnet_cidr, 8, 0) is left unused: it held the Application
# Gateway subnet, and renumbering the subnets below would force Terraform to
# replace them.

resource "azurerm_subnet" "containerapps" {
  # /23: more than the /27 a workload profiles environment needs
  # (containerapps.tf), kept so the subnet is not replaced and so the
  # environment has room to scale out replicas.
  name                 = "${var.name_prefix}-containerapps"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 7, 1)]

  delegation {
    name = "containerapps"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "postgres" {
  # Delegated-subnet VNet integration, not a private endpoint: this is the
  # pattern Postgres Flexible Server's own official example uses, and the
  # more common of the two private-connectivity modes the service offers —
  # see postgres.tf's own comment for the deviation from a private-endpoint
  # design here.
  name                 = "${var.name_prefix}-postgres"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 8, 4)]

  delegation {
    name = "postgres"
    service_delegation {
      name    = "Microsoft.DBforPostgreSQL/flexibleServers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "private_endpoints" {
  # Shared by every azurerm_private_endpoint in this stack (storage
  # blob+file, Key Vault, ACR, Redis — privateendpoints.tf) — unlike the
  # postgres/containerapps subnets above, private endpoints carry no exclusivity
  # requirement, so one subnet for all of them is the honest floor rather
  # than a separate one per service with nothing to isolate from the
  # others (every private endpoint here is reached by the same caller,
  # containerapps, on the same port, 443).
  name                 = "${var.name_prefix}-private-endpoints"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 8, 5)]
}

# ---- NAT egress ----------------------------------------------------------
# containerapps.tf's api/worker containers call out to the same public
# internet endpoints the AWS stack's ecs_tasks security group documents
# (AI provider APIs, Nominatim, VIES, crt.sh, OAuth token endpoints, license
# validation, outbound mail) — none of this stack's OTHER services need
# internet egress (Postgres/Redis/Storage/Key Vault/ACR are all reached over
# a private endpoint or VNet integration instead), so the NAT gateway attaches
# to the containerapps subnet only.
#
# This is NOT zone-redundant, unlike the AWS stack's one-NAT-gateway-per-AZ:
# a Standard-SKU NAT Gateway pins to at most ONE zone in a single resource
# (Azure's own docs on the resource: "for Standard, zones may be omitted for a
# no-zone deployment or set to a single Availability Zone"). Azure's newer
# StandardV2 SKU is documented as zone-redundant by default in one resource,
# which would close this gap without needing N NAT gateways behind N
# zone-pinned subnets the way AWS needs — this stack does not default to
# StandardV2 because its GA maturity/regional availability could not be
# confirmed from within the environment this stack was built in. An operator
# who wants AWS-equivalent NAT resilience should re-evaluate StandardV2 first,
# rather than reach for N Standard NAT gateways behind N new zone-pinned
# subnets Container Apps/Postgres/Redis do not otherwise need — those
# resources are zone-redundant at the RESOURCE level already (postgres.tf,
# containerapps.tf), not the subnet level.
resource "azurerm_public_ip" "nat" {
  name                = "${var.name_prefix}-nat"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-nat", Component = "network" })
}

resource "azurerm_nat_gateway" "this" {
  name                = "${var.name_prefix}-nat"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku_name            = "Standard"
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-nat", Component = "network" })
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  nat_gateway_id       = azurerm_nat_gateway.this.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "containerapps" {
  subnet_id      = azurerm_subnet.containerapps.id
  nat_gateway_id = azurerm_nat_gateway.this.id
}

# ---- Network security groups ------------------------------------------------
# One per tier, deny-by-default with only the documented traffic allowed —
# same scoping logic as the AWS stack's security groups (network.tf there):
# ingress named explicitly, egress narrowed to what that tier genuinely
# originates. NSGs attach to a SUBNET here rather than to one ENI per
# resource the way an AWS security group does, because private endpoints and
# the Postgres delegated subnet do not each get their own NIC-level construct
# to attach a resource-scoped NSG to the way an aws_security_group does.

resource "azurerm_network_security_group" "containerapps" {
  name                = "${var.name_prefix}-containerapps"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-containerapps", Component = "network" })

  # Public traffic to the api app (the only external ingress) reaches an
  # external workload profiles environment through its public IP in the
  # managed resource group, not through this subnet, so these inbound rules
  # do not filter it (learn.microsoft.com/azure/container-apps/
  # firewall-integration). They are kept for the platform's HTTP-to-HTTPS
  # redirect and load balancer probes; intra-subnet traffic between the
  # environment's components rides the default AllowVnetInBound rule.
  security_rule {
    name                       = "AllowHttpsInbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowHttpInboundForRedirectOnly"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowAzureLoadBalancerInbound"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "containerapps" {
  subnet_id                 = azurerm_subnet.containerapps.id
  network_security_group_id = azurerm_network_security_group.containerapps.id
}

resource "azurerm_network_security_group" "postgres" {
  name                = "${var.name_prefix}-postgres"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-postgres", Component = "database" })

  security_rule {
    name                       = "AllowPostgresFromContainerApps"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "5432"
    source_address_prefix      = azurerm_subnet.containerapps.address_prefixes[0]
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "postgres" {
  subnet_id                 = azurerm_subnet.postgres.id
  network_security_group_id = azurerm_network_security_group.postgres.id
}

resource "azurerm_network_security_group" "private_endpoints" {
  name                = "${var.name_prefix}-private-endpoints"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-private-endpoints", Component = "network" })

  security_rule {
    name                       = "AllowHttpsFromContainerApps"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = azurerm_subnet.containerapps.address_prefixes[0]
    destination_address_prefix = "*"
  }

  # Redis's private endpoint (privateendpoints.tf) answers on 6380 (TLS-only —
  # see redis.tf), not 443 like the other three private endpoints sharing
  # this subnet.
  security_rule {
    name                       = "AllowRedisFromContainerApps"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "6380"
    source_address_prefix      = azurerm_subnet.containerapps.address_prefixes[0]
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "private_endpoints" {
  subnet_id                 = azurerm_subnet.private_endpoints.id
  network_security_group_id = azurerm_network_security_group.private_endpoints.id
}

# ---- Observability sink -----------------------------------------------------
# One Log Analytics workspace for the whole stack, rather than the AWS
# stack's one CloudWatch Log Group per service (rds.tf, elasticache.tf,
# iam.tf, alb.tf) — Log Analytics + a per-resource diagnostic setting is
# Azure's own idiom for centralizing this, so containerapps.tf's Container
# App Environment, this file's own flow log and postgres.tf
# all send here instead of each minting its own destination.
resource "azurerm_log_analytics_workspace" "this" {
  name                = "${var.name_prefix}-logs"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = var.log_retention_days
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-logs", Component = "observability" })
}

# ---- Flow logs: a real, currently-unfillable gap, stated plainly ------------
# Every NSG above is a claim about what traffic is allowed — nothing records
# what traffic actually flowed, accepted or rejected (same reasoning as the
# AWS stack's aws_flow_log.this, network.tf there), and this stack cannot
# close that gap with the provider version it pins:
#   - Azure's control plane has refused to create a NEW NSG-scoped flow log
#     since June 30, 2025 (existing ones keep running until the whole feature
#     retires on September 30, 2027) — a fresh
#     azurerm_network_watcher_flow_log with network_security_group_id would
#     be rejected at apply time, not just discouraged.
#   - VNet-scoped flow logs are Azure's own replacement, but this resource's
#     target_resource_id argument (the one that lets it target a VNet instead
#     of an NSG) does not exist in the azurerm provider's 3.x line at all —
#     confirmed against the resource's own schema at v3.117.1, the newest 3.x
#     release the provider has shipped (versions.tf pins "~> 3.117"). It
#     requires the provider's 4.x line, which renames enough other arguments
#     this stack already depends on (azurerm_key_vault's own
#     rbac_authorization_enabled, found and fixed only because
#     `terraform validate` caught it, is one example) that upgrading to reach
#     one resource is a wider migration than this change should fold in
#     silently.
#
# Left undone rather than shipped broken: a resource `terraform apply` would
# refuse is worse than no resource at all. An operator who upgrades this
# stack's provider constraint to azurerm 4.x can add
# azurerm_network_watcher_flow_log back with target_resource_id =
# azurerm_virtual_network.this.id, a storage account destination, and a
# traffic_analytics block pointed at the Log Analytics workspace below — the
# same shape this comment once carried before validation disproved it.
resource "azurerm_network_watcher" "this" {
  name                = "${var.name_prefix}-nw"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-nw", Component = "observability" })
}
