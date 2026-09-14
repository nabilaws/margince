output "appgw_public_ip" {
  value = azurerm_public_ip.appgw.ip_address
}

output "appgw_fqdn" {
  description = "Point public_base_url's host at this (a CNAME) — Application Gateway's public IP has no Azure-assigned FQDN of its own the way an ALB gets a dns_name, unlike aws/README.md's own alb_dns_name output."
  value       = azurerm_public_ip.appgw.fqdn
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
