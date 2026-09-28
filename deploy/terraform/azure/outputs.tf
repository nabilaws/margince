output "public_default_fqdn" {
  description = "CNAME target for public_base_url's host (README.md, DNS step): the api app's ingress, served by its edge container."
  value       = azurerm_container_app.api.ingress[0].fqdn
}

output "custom_domain_verification_id" {
  description = "Value of the asuid.<host> TXT record Container Apps checks before bind_custom_domain can be set to true."
  value       = azurerm_container_app_environment.this.custom_domain_verification_id
}

output "environment_static_ip" {
  description = "Public inbound IP of the Container Apps environment (for an A record, if the DNS zone cannot hold a CNAME at this name)."
  value       = azurerm_container_app_environment.this.static_ip_address
}

output "nat_egress_ip" {
  description = "The one address api and worker call out from. Add it to the Dataverse environment's IP firewall (Managed Environments) and to any partner allowlist."
  value       = azurerm_public_ip.nat.ip_address
}

output "entra_tenant_id" {
  value = local.entra_tenant_id
}

output "entra_client_id" {
  description = "Application (client) ID of the Margince app registration. Add this app to the Conditional Access policy that protects Dataverse."
  value       = local.entra_client_id
}

output "entra_redirect_uris" {
  description = "Redirect URIs the app registration must list (set by entra.tf when create_entra_app = true; enter by hand otherwise)."
  value       = local.entra_redirect_uris
}

output "dataverse_identity_client_id" {
  description = "Client ID to register as a Dataverse application user (Power Platform admin center, Environment, Settings, Application users)."
  value       = azurerm_user_assigned_identity.dataverse.client_id
}

output "dataverse_identity_principal_id" {
  value = azurerm_user_assigned_identity.dataverse.principal_id
}

output "container_app_environment_name" {
  value = azurerm_container_app_environment.this.name
}

output "acr_login_server" {
  value = azurerm_container_registry.this.login_server
}

output "acr_repository_names" {
  description = "ACR has no Terraform-managed repository resource the way ECR does (acr.tf's own comment) — repositories are created implicitly on first push, so this is the conventional name each role's image is pushed under, not a resource this stack provisions."
  value = {
    api    = "${azurerm_container_registry.this.login_server}/api"
    worker = "${azurerm_container_registry.this.login_server}/worker"
    web    = "${azurerm_container_registry.this.login_server}/web"
  }
}

output "postgres_fqdn" {
  value = azurerm_postgresql_flexible_server.this.fqdn
}

output "redis_hostname" {
  value = azurerm_redis_cache.this.hostname
}

output "storage_account_name" {
  value = azurerm_storage_account.this.name
}

output "key_vault_uri" {
  value = azurerm_key_vault.this.vault_uri
}

output "log_analytics_workspace_id" {
  value = azurerm_log_analytics_workspace.this.id
}

output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "acr_name" {
  value = azurerm_container_registry.this.name
}

output "jumpbox_name" {
  description = "Empty when enable_jumpbox is false."
  value       = var.enable_jumpbox ? azurerm_linux_virtual_machine.jumpbox[0].name : ""
}

output "jumpbox_private_ip" {
  value = var.enable_jumpbox ? azurerm_linux_virtual_machine.jumpbox[0].private_ip_address : ""
}

output "jumpbox_admin_username" {
  value = var.jumpbox_admin_username
}
