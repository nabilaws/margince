# Path rules below mirror alb.tf's own listener rules exactly:
# api_v1_and_ops / api_webhooks / api_mcp_oauth all forward to api, and
# everything else — "/" included — falls through to web, the identical
# routing docs/deployment.md's own table describes.

resource "azurerm_public_ip" "appgw" {
  name                = "${var.name_prefix}-appgw"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  # Unlike an ALB (aws/alb.tf), a bare Azure public IP has no Azure-assigned
  # DNS name of its own — domain_name_label is what requests one
  # (<label>.<region>.cloudapp.azure.com, outputs.tf's own appgw_fqdn), so an
  # operator without their own zone still has a stable host name to point at
  # rather than only the IP address itself.
  domain_name_label = "${var.name_prefix}-appgw"
  tags              = merge(local.common_tags, { Name = "${var.name_prefix}-appgw", Component = "edge" })
}

# Application Gateway's own identity, scoped to exactly one grant: reading
# the TLS certificate this stack imports into Key Vault (variables.tf's own
# tls_certificate_key_vault_secret_id) — not the data_cmk identity
# (identity.tf), which exists for a different set of consumers (Storage,
# Postgres, ACR) with no reason to also hold this one.
resource "azurerm_user_assigned_identity" "appgw" {
  name                = "${var.name_prefix}-appgw"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = merge(local.common_tags, { Name = "${var.name_prefix}-appgw", Component = "security" })
}

resource "azurerm_role_assignment" "appgw_key_vault_secrets_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.appgw.principal_id
}

resource "azurerm_web_application_firewall_policy" "this" {
  name                = "${var.name_prefix}-waf"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  managed_rules {
    managed_rule_set {
      type    = "OWASP"
      version = "3.2"
    }
  }

  policy_settings {
    enabled = true
    # Prevention, not Detection: matches the AWS stack's own reasoning
    # (alb.tf's WAFv2 web ACL comment) — every rule here runs in blocking
    # mode because this stack has no other layer in front of it to catch
    # what a detection-only mode would merely log.
    mode = "Prevention"
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-waf", Component = "edge" })
}

resource "azurerm_application_gateway" "this" {
  name                = "${var.name_prefix}-appgw"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  zones               = ["1", "2", "3"]
  firewall_policy_id  = azurerm_web_application_firewall_policy.this.id

  sku {
    name = "WAF_v2"
    tier = "WAF_v2"
  }

  # Ceiling/floor for the platform's own autoscaling — the closest Application
  # Gateway equivalent to ecs.tf's aws_appautoscaling_target on api/worker.
  # There is no CPU metric to target here: v2 SKU capacity is priced and
  # scaled in Capacity Units the platform sizes on its own, so unlike ECS
  # there is no policy resource to define, only the bounds it scales within.
  autoscale_configuration {
    min_capacity = var.appgw_min_capacity
    max_capacity = var.appgw_max_capacity
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.appgw.id]
  }

  gateway_ip_configuration {
    name      = "appgw"
    subnet_id = azurerm_subnet.appgw.id
  }

  frontend_ip_configuration {
    name                 = "public"
    public_ip_address_id = azurerm_public_ip.appgw.id
  }

  frontend_port {
    name = "http"
    port = 80
  }

  frontend_port {
    name = "https"
    port = 443
  }

  ssl_certificate {
    name                = "tls"
    key_vault_secret_id = var.tls_certificate_key_vault_secret_id
  }

  # HTTP -> HTTPS redirect only — the AWS stack's own aws_lb_listener.http_redirect.
  http_listener {
    name                           = "http"
    frontend_ip_configuration_name = "public"
    frontend_port_name             = "http"
    protocol                       = "Http"
  }

  http_listener {
    name                           = "https"
    frontend_ip_configuration_name = "public"
    frontend_port_name             = "https"
    protocol                       = "Https"
    ssl_certificate_name           = "tls"
  }

  # HTTP hop from here to the Container Apps targets, deliberately — same
  # reasoning as alb.tf's own comment: cmd/api serves plain HTTP and
  # terminates TLS ahead of itself; TLS terminates at this gateway, and the
  # hop onward stays inside this VNet, never on the public internet.
  # containerapps.tf's own ingress blocks set allow_insecure_connections =
  # true on api/web for exactly this pairing.
  backend_http_settings {
    name                  = "api"
    port                  = 8080
    protocol              = "Http"
    cookie_based_affinity = "Disabled"
    probe_name            = "api"
  }

  backend_http_settings {
    name                  = "web"
    port                  = 8080
    protocol              = "Http"
    cookie_based_affinity = "Disabled"
    probe_name            = "web"
  }

  probe {
    name                = "api"
    protocol            = "Http"
    path                = "/healthz"
    host                = azurerm_container_app.api.ingress[0].fqdn
    interval            = 15
    timeout             = 5
    unhealthy_threshold = 3
  }

  probe {
    name                = "web"
    protocol            = "Http"
    path                = "/"
    host                = azurerm_container_app.web.ingress[0].fqdn
    interval            = 15
    timeout             = 5
    unhealthy_threshold = 3
  }

  backend_address_pool {
    name  = "api"
    fqdns = [azurerm_container_app.api.ingress[0].fqdn]
  }

  backend_address_pool {
    name  = "web"
    fqdns = [azurerm_container_app.web.ingress[0].fqdn]
  }

  # Default action for the https listener: everything not matched by a
  # path_rule below falls through here, to web — mirrors alb.tf's own
  # aws_lb_listener.https default_action (target_group_arn = web).
  url_path_map {
    name                               = "routing"
    default_backend_address_pool_name  = "web"
    default_backend_http_settings_name = "web"

    path_rule {
      name                       = "api-v1-and-ops"
      paths                      = ["/v1/*", "/healthz", "/readyz", "/metrics"]
      backend_address_pool_name  = "api"
      backend_http_settings_name = "api"
    }

    path_rule {
      name                       = "api-webhooks"
      paths                      = ["/webhooks/gmail", "/webhooks/graph", "/webhooks/hubspot"]
      backend_address_pool_name  = "api"
      backend_http_settings_name = "api"
    }

    path_rule {
      name = "api-mcp-oauth"
      paths = [
        "/oauth/*",
        "/mcp*",
        "/.well-known/oauth-authorization-server",
        "/.well-known/oauth-protected-resource",
        "/.well-known/oauth-protected-resource/mcp",
      ]
      backend_address_pool_name  = "api"
      backend_http_settings_name = "api"
    }
  }

  request_routing_rule {
    name               = "https"
    rule_type          = "PathBasedRouting"
    http_listener_name = "https"
    url_path_map_name  = "routing"
    priority           = 100
  }

  request_routing_rule {
    name                        = "http-redirect"
    rule_type                   = "Basic"
    http_listener_name          = "http"
    redirect_configuration_name = "https-redirect"
    priority                    = 200
  }

  redirect_configuration {
    name                 = "https-redirect"
    redirect_type        = "Permanent"
    target_listener_name = "https"
    include_path         = true
    include_query_string = true
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-appgw", Component = "edge" })

  depends_on = [azurerm_role_assignment.appgw_key_vault_secrets_user]

  # alb.tf's path patterns (/v1*, /mcp*, …) are ALB's own wildcard syntax,
  # ported here to Application Gateway's own path-pattern matching
  # ("/v1/*", trailing-wildcard segments) rather than copied byte-for-byte —
  # the two engines' wildcard grammars are not identical. Verify each
  # path_rule above against a real request before relying on it; this is a
  # best-effort port, not a confirmed one, the same honesty this stack's
  # other unverified specifics (identity.tf's ABAC comment, network.tf's
  # StandardV2 comment) already carry.
}

resource "azurerm_monitor_diagnostic_setting" "appgw" {
  name                       = "${var.name_prefix}-appgw"
  target_resource_id         = azurerm_application_gateway.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category = "ApplicationGatewayAccessLog"
  }
  enabled_log {
    category = "ApplicationGatewayPerformanceLog"
  }
  enabled_log {
    category = "ApplicationGatewayFirewallLog"
  }

  metric {
    category = "AllMetrics"
  }
}
