# Operator jumpbox: one small Linux VM inside the VNet, for everything that
# must reach the private endpoints (Postgres has no public endpoint at all):
#
#   - the "cloud" image build (scripts/build-images.sh cloud): builds
#     linux/amd64 images natively and pushes them to the registry over its
#     private endpoint, using the VM's managed identity (AcrPush);
#   - the one-time database bootstrap (README.md step 3);
#   - writing margince.yaml onto the config share (step 5).
#
# No public IP. Reach it through Azure Bastion's free Developer tier (browser
# SSH from the portal) or `az vm run-command invoke` from any machine logged
# in to Azure. It shuts down every evening; start it on demand.

locals {
  jumpbox_enabled = var.enable_jumpbox ? 1 : 0
}

resource "azurerm_subnet" "ops" {
  count                = local.jumpbox_enabled
  name                 = "${var.name_prefix}-ops"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.vnet_cidr, 8, 6)]
}

# Outbound through the same NAT (apt, GitHub, Docker Hub) from the same fixed
# address as the apps.
resource "azurerm_subnet_nat_gateway_association" "ops" {
  count          = local.jumpbox_enabled
  subnet_id      = azurerm_subnet.ops[0].id
  nat_gateway_id = azurerm_nat_gateway.this.id
}

resource "azurerm_network_security_group" "ops" {
  count               = local.jumpbox_enabled
  name                = "${var.name_prefix}-ops"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-ops", Component = "network" })

  # Bastion Developer connects to the VM's private IP from Azure's platform
  # address 168.63.129.16. Nothing else may open SSH.
  security_rule {
    name                       = "AllowBastionDeveloperSsh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "168.63.129.16"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "DenySshFromElsewhere"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "ops" {
  count                     = local.jumpbox_enabled
  subnet_id                 = azurerm_subnet.ops[0].id
  network_security_group_id = azurerm_network_security_group.ops[0].id
}

resource "azurerm_network_interface" "jumpbox" {
  count               = local.jumpbox_enabled
  name                = "${var.name_prefix}-jumpbox"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-jumpbox", Component = "operations" })

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.ops[0].id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "jumpbox" {
  count                           = local.jumpbox_enabled
  name                            = "${var.name_prefix}-jumpbox"
  location                        = azurerm_resource_group.this.location
  resource_group_name             = azurerm_resource_group.this.name
  size                            = var.jumpbox_vm_size
  admin_username                  = var.jumpbox_admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.jumpbox[0].id]
  custom_data                     = base64encode(templatefile("${path.module}/templates/jumpbox-cloud-init.yaml.tftpl", { admin_username = var.jumpbox_admin_username }))
  tags                            = merge(local.common_tags, { Name = "${var.name_prefix}-jumpbox", Component = "operations" })

  admin_ssh_key {
    username   = var.jumpbox_admin_username
    public_key = var.jumpbox_ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 64 # room for the Docker build cache
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  identity {
    type = "SystemAssigned"
  }

  lifecycle {
    precondition {
      condition     = length(trimspace(var.jumpbox_ssh_public_key)) > 0
      error_message = "enable_jumpbox = true needs jumpbox_ssh_public_key."
    }
    # A new image version must not replace a jumpbox holding a build cache.
    ignore_changes = [custom_data, source_image_reference]
  }
}

# The cloud build pushes with the VM's own identity; it holds nothing else.
resource "azurerm_role_assignment" "jumpbox_acr_push" {
  count                = local.jumpbox_enabled
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPush"
  principal_id         = azurerm_linux_virtual_machine.jumpbox[0].identity[0].principal_id
}

resource "azurerm_dev_test_global_vm_shutdown_schedule" "jumpbox" {
  count                 = local.jumpbox_enabled
  virtual_machine_id    = azurerm_linux_virtual_machine.jumpbox[0].id
  location              = azurerm_resource_group.this.location
  enabled               = true
  daily_recurrence_time = var.jumpbox_shutdown_time
  timezone              = var.jumpbox_shutdown_timezone

  notification_settings {
    enabled = false
  }
}

# Free tier: browser SSH from the portal to VMs in this VNet, no public IP and
# no subnet of its own.
resource "azurerm_bastion_host" "developer" {
  count               = var.enable_jumpbox && var.enable_bastion_developer ? 1 : 0
  name                = "${var.name_prefix}-bastion"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "Developer"
  virtual_network_id  = azurerm_virtual_network.this.id
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-bastion", Component = "operations" })
}
