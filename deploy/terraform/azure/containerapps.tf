resource "azurerm_container_app_environment" "this" {
  name                = "${var.name_prefix}-env"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  infrastructure_subnet_id   = azurerm_subnet.containerapps.id

  # External: the environment gets a public load balancer, but only apps with
  # external_enabled ingress are reachable through it, and that is the api app
  # alone, through its edge (nginx) container. worker has no ingress. There is
  # no gateway in front (templates/edge-nginx.conf.tftpl).
  #
  # Changing this on an existing environment forces Terraform to replace the
  # environment and all three apps (README.md, "Moving from the Application
  # Gateway layout").
  internal_load_balancer_enabled = false

  # Zone redundancy needs the environment's subnet at creation time
  # (network.tf's azurerm_subnet.containerapps, /23).
  zone_redundancy_enabled = var.az_count >= 2

  # A workload profiles environment running only the serverless Consumption
  # profile: same per-second billing as a Consumption-only environment, but
  # the Consumption-only type (legacy) does not support egress through NAT
  # Gateway, so network.tf's NAT would not give api/worker a fixed outbound
  # IP (learn.microsoft.com/azure/container-apps/networking). That fixed IP
  # is what the Dataverse IP firewall allowlists (nat_egress_ip output).
  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-env", Component = "compute" })
}

# Mounted read-only at /app/config on api and worker — mirrors efs.tf's own
# access_point mount exactly (same margince.yaml, same one-time `cp` an
# operator runs, documented in azure/README.md rather than done by Terraform
# here).
resource "azurerm_container_app_environment_storage" "config" {
  name                         = "config"
  container_app_environment_id = azurerm_container_app_environment.this.id
  account_name                 = azurerm_storage_account.this.name
  share_name                   = azurerm_storage_share.config.name
  access_key                   = azurerm_storage_account.this.primary_access_key
  access_mode                  = "ReadOnly"
}

# Read-write attachment store for api and worker (storage.tf's attachments
# share), exposed to Margince as MARGINCE_BLOBSTORE_PATH.
resource "azurerm_container_app_environment_storage" "attachments" {
  name                         = "attachments"
  container_app_environment_id = azurerm_container_app_environment.this.id
  account_name                 = azurerm_storage_account.this.name
  share_name                   = azurerm_storage_share.attachments.name
  access_key                   = azurerm_storage_account.this.primary_access_key
  access_mode                  = "ReadWrite"
}

locals {
  # DSNs/connection info assembled once in secrets.tf's own locals block
  # (local.owner_dsn, local.app_dsn, local.redis_host) — referenced from
  # there via the key_vault_secret this file's own `secret` blocks point at,
  # the same one-Secrets-Manager-entry-per-credential shape ecs.tf's own
  # shared_secrets list uses.
  container_apps_secrets = [
    { name = "owner-dsn", key_vault_secret_id = azurerm_key_vault_secret.owner_dsn.versionless_id, env = "MARGINCE_OWNER_DSN" },
    { name = "app-dsn", key_vault_secret_id = azurerm_key_vault_secret.app_dsn.versionless_id, env = "MARGINCE_DSN" },
    { name = "redis-password", key_vault_secret_id = azurerm_key_vault_secret.redis_password.versionless_id, env = "MARGINCE_REDIS_PASSWORD" },
    { name = "keyvault-root-key", key_vault_secret_id = azurerm_key_vault_secret.keyvault_root_key.versionless_id, env = "MARGINCE_KEYVAULT_ROOT_KEY" },
    { name = "webhook-key", key_vault_secret_id = azurerm_key_vault_secret.webhook_key.versionless_id, env = "MARGINCE_WEBHOOK_KEY" },
    { name = "connector-state-key", key_vault_secret_id = azurerm_key_vault_secret.connector_state_key.versionless_id, env = "MARGINCE_CONNECTOR_STATE_KEY" },
    { name = "admin-password", key_vault_secret_id = azurerm_key_vault_secret.admin_password.versionless_id, env = "MARGINCE_ADMIN_PASSWORD" },
    { name = "license", key_vault_secret_id = azurerm_key_vault_secret.license.versionless_id, env = "MARGINCE_LICENSE" },
    { name = "entra-client-secret", key_vault_secret_id = azurerm_key_vault_secret.entra_client_secret.versionless_id, env = "MARGINCE_GRAPH_CLIENT_SECRET" },
  ]

  # Attachments use Margince's filesystem store on the attachments share
  # (MARGINCE_BLOBSTORE_PATH), because its object-store client speaks S3 only
  # and this account's blob API is not S3 (storage.tf).
  shared_env = [
    { name = "MARGINCE_CONFIG", value = "/app/config/margince.yaml" },
    # 6380: Azure Cache for Redis's TLS-only port (redis.tf's
    # enable_non_ssl_port = false leaves no plaintext 6379 to fall back to).
    { name = "MARGINCE_REDIS", value = "${azurerm_redis_cache.this.hostname}:6380" },
    { name = "MARGINCE_REDIS_TLS", value = "true" },
    { name = "MARGINCE_PUBLIC_BASE_URL", value = var.public_base_url },
    { name = "MARGINCE_LOG_FORMAT", value = "json" },
    { name = "MARGINCE_BLOBSTORE_PATH", value = "/app/blobstore" },
    # Entra ID (entra.tf): one app for staff sign-in and Graph capture, pinned
    # to the customer's tenant. MARGINCE_MICROSOFT_SIGNIN_TENANT is what turns
    # Microsoft sign-in on and refuses every other directory.
    { name = "MARGINCE_GRAPH_CLIENT_ID", value = local.entra_client_id },
    { name = "MARGINCE_GRAPH_TENANT", value = local.entra_tenant_id },
    { name = "MARGINCE_MICROSOFT_SIGNIN_TENANT", value = local.entra_tenant_id },
  ]

  # The edge container's complete nginx config (templates/edge-nginx.conf.tftpl).
  # Not a secret: it is passed as a plain environment variable and written to
  # /tmp at start, so no file share or secret volume is involved.
  edge_port = 8081
  api_port  = 8080 # cmd/api's --addr default
  edge_nginx_conf = templatefile("${path.module}/templates/edge-nginx.conf.tftpl", {
    edge_port         = local.edge_port
    api_port          = local.api_port
    envoy_cidr        = azurerm_subnet.containerapps.address_prefixes[0]
    break_glass_cidrs = var.break_glass_cidrs
    auth_rate         = var.auth_rate_limit_per_minute
  })

  public_host = trimprefix(var.public_base_url, "https://")
}

resource "azurerm_container_app" "api" {
  name                         = "${var.name_prefix}-api"
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = azurerm_resource_group.this.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  identity {
    type = "UserAssigned"
    identity_ids = [
      azurerm_user_assigned_identity.api_worker.id,
      azurerm_user_assigned_identity.dataverse.id,
    ]
  }

  registry {
    server   = azurerm_container_registry.this.login_server
    identity = azurerm_user_assigned_identity.api_worker.id
  }

  dynamic "secret" {
    for_each = local.container_apps_secrets
    content {
      name                = secret.value.name
      key_vault_secret_id = secret.value.key_vault_secret_id
      identity            = azurerm_user_assigned_identity.api_worker.id
    }
  }

  # The one public ingress in the stack. It targets the edge container, never
  # cmd/api directly: edge serves the SPA, applies the break-glass and rate
  # rules, and forwards api paths to cmd/api on localhost. TLS ends at the
  # environment's edge; HTTP is redirected to HTTPS.
  ingress {
    external_enabled           = true
    target_port                = local.edge_port
    allow_insecure_connections = false
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.api_min_replicas
    max_replicas = var.api_max_replicas

    volume {
      name         = "config"
      storage_name = azurerm_container_app_environment_storage.config.name
      storage_type = "AzureFile"
    }

    volume {
      name         = "attachments"
      storage_name = azurerm_container_app_environment_storage.attachments.name
      storage_type = "AzureFile"
    }

    container {
      name   = "api"
      image  = "${azurerm_container_registry.this.login_server}/api:${var.image_tag}"
      cpu    = var.api_cpu
      memory = var.api_memory

      dynamic "env" {
        for_each = local.shared_env
        content {
          name  = env.value.name
          value = env.value.value
        }
      }

      dynamic "env" {
        for_each = local.container_apps_secrets
        content {
          name        = env.value.env
          secret_name = env.value.name
        }
      }

      volume_mounts {
        name = "config"
        path = "/app/config"
      }

      volume_mounts {
        name = "attachments"
        path = "/app/blobstore"
      }
    }

    # edge: nginx from the web image (it carries the built SPA), sharing this
    # replica's network namespace with cmd/api. See
    # templates/edge-nginx.conf.tftpl. api_cpu + web_cpu and api_memory +
    # web_memory must add up to a valid Consumption combination (the defaults
    # give 0.75 vCPU / 1.5Gi).
    container {
      name    = "edge"
      image   = "${azurerm_container_registry.this.login_server}/web:${var.image_tag}"
      cpu     = var.web_cpu
      memory  = var.web_memory
      command = ["/bin/sh", "-c"]
      args    = ["printf '%s' \"$NGINX_CONF\" > /tmp/nginx.conf && exec nginx -c /tmp/nginx.conf -g 'daemon off;'"]

      env {
        name  = "NGINX_CONF"
        value = local.edge_nginx_conf
      }

      # Ready only once cmd/api answers through the edge, so a new replica
      # takes no traffic while nginx is up and cmd/api is still starting.
      # /healthz, not /readyz: readyz also weighs the AI and embedding state
      # (compose/routes.go), which should not take replicas out of rotation.
      readiness_probe {
        transport = "HTTP"
        port      = local.edge_port
        path      = "/healthz"
      }

      liveness_probe {
        transport = "HTTP"
        port      = local.edge_port
        path      = "/healthz"
      }
    }

    # CPU utilization target-tracking, same 70% threshold as ecs.tf's own
    # aws_appautoscaling_policy.api_cpu — api_min_replicas keeps this service
    # warm (never scale-to-zero, unlike worker below), so a cpu-type KEDA
    # rule is unambiguous here: there is always at least one replica for it
    # to sample.
    custom_scale_rule {
      name             = "cpu-scaling"
      custom_rule_type = "cpu"
      metadata = {
        type  = "Utilization"
        value = "70"
      }
    }
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-api", Component = "compute-api" })
}

resource "azurerm_container_app" "worker" {
  name                         = "${var.name_prefix}-worker"
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = azurerm_resource_group.this.name
  revision_mode                = "Single"
  workload_profile_name        = "Consumption"

  identity {
    type = "UserAssigned"
    identity_ids = [
      azurerm_user_assigned_identity.api_worker.id,
      azurerm_user_assigned_identity.dataverse.id,
    ]
  }

  registry {
    server   = azurerm_container_registry.this.login_server
    identity = azurerm_user_assigned_identity.api_worker.id
  }

  dynamic "secret" {
    for_each = local.container_apps_secrets
    content {
      name                = secret.value.name
      key_vault_secret_id = secret.value.key_vault_secret_id
      identity            = azurerm_user_assigned_identity.api_worker.id
    }
  }

  # No ingress block — worker has no listener, matching ecs.tf's own
  # aws_ecs_service.worker (no load_balancer block there either).

  template {
    min_replicas = var.worker_min_replicas
    max_replicas = var.worker_max_replicas

    volume {
      name         = "config"
      storage_name = azurerm_container_app_environment_storage.config.name
      storage_type = "AzureFile"
    }

    volume {
      name         = "attachments"
      storage_name = azurerm_container_app_environment_storage.attachments.name
      storage_type = "AzureFile"
    }

    container {
      name   = "worker"
      image  = "${azurerm_container_registry.this.login_server}/worker:${var.image_tag}"
      cpu    = var.worker_cpu
      memory = var.worker_memory

      dynamic "env" {
        for_each = concat(local.shared_env, [
          { name = "MARGINCE_OBSERVE_ADDR", value = "0.0.0.0:9101" },
        ])
        content {
          name  = env.value.name
          value = env.value.value
        }
      }

      dynamic "env" {
        for_each = local.container_apps_secrets
        content {
          name        = env.value.env
          secret_name = env.value.name
        }
      }

      volume_mounts {
        name = "config"
        path = "/app/config"
      }

      volume_mounts {
        name = "attachments"
        path = "/app/blobstore"
      }
    }

    # var.worker_min_replicas defaults to 1: a cpu-type rule needs a running
    # replica to sample and cannot lift worker from zero on its own, and
    # worker owns the periodic jobs (capture sync, AI passes) that must always
    # run. This rule only adds replicas above that floor under load.
    custom_scale_rule {
      name             = "cpu-scaling"
      custom_rule_type = "cpu"
      metadata = {
        type  = "Utilization"
        value = "70"
      }
    }
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-worker", Component = "compute-worker" })
}

# public_base_url's host on the api app (the public ingress). Two-phase (variables.tf,
# bind_custom_domain): the DNS records must exist before this can be created.
# The managed certificate is then issued and bound outside Terraform by
# `az containerapp hostname bind` (README.md), which is why the certificate
# fields are ignored here: azurerm ~> 3.117 cannot create a managed
# certificate itself.
resource "azurerm_container_app_custom_domain" "public" {
  count            = var.bind_custom_domain ? 1 : 0
  name             = local.public_host
  container_app_id = azurerm_container_app.api.id

  lifecycle {
    ignore_changes = [certificate_binding_type, container_app_environment_certificate_id]
  }
}
