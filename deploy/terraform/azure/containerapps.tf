resource "azurerm_container_app_environment" "this" {
  name                = "${var.name_prefix}-env"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id
  infrastructure_subnet_id   = azurerm_subnet.containerapps.id

  # No public ingress on the environment itself — appgateway.tf is this
  # stack's one public entry point, the same "ECS tasks have no public IP,
  # only the ALB does" shape as the AWS stack (ecs.tf's
  # network_configuration.assign_public_ip = false).
  internal_load_balancer_enabled = true

  # network.tf's own azurerm_subnet.containerapps comment already sizes that
  # subnet at /23 specifically for this — Consumption-only zone redundancy
  # needs it, and a smaller subnet is refused at apply time regardless of
  # this setting.
  zone_redundancy_enabled = var.az_count >= 2

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
  ]

  # MARGINCE_BLOBSTORE_* is deliberately absent — see storage.tf's own
  # top-of-file comment: the Go blobstore client cannot talk to this
  # account's native API, so there is nothing correct to point it at yet.
  shared_env = [
    { name = "MARGINCE_CONFIG", value = "/app/config/margince.yaml" },
    # 6380: Azure Cache for Redis's TLS-only port (redis.tf's
    # enable_non_ssl_port = false leaves no plaintext 6379 to fall back to).
    { name = "MARGINCE_REDIS", value = "${azurerm_redis_cache.this.hostname}:6380" },
    { name = "MARGINCE_REDIS_TLS", value = "true" },
    { name = "MARGINCE_PUBLIC_BASE_URL", value = var.public_base_url },
    { name = "MARGINCE_LOG_FORMAT", value = "json" },
  ]
}

resource "azurerm_container_app" "api" {
  name                         = "${var.name_prefix}-api"
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = azurerm_resource_group.this.name
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.api_worker.id]
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

  # appgateway.tf's backend_http_settings talks plain HTTP to this app on
  # 8080 — same reasoning as alb.tf's own comment: cmd/api serves plain HTTP
  # and terminates TLS ahead of itself, so allow_insecure_connections here is
  # what lets Application Gateway (TLS already terminated at ITS edge) reach
  # it without asking cmd/api to speak a protocol it does not implement.
  ingress {
    external_enabled           = false
    target_port                = 8080
    allow_insecure_connections = true
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

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.api_worker.id]
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
    }

    # var.worker_min_replicas defaults to 0 (variables.tf's own comment:
    # idle-cost traded for a cold start, since worker has no ingress to keep
    # warm for). Azure Container Apps documents that a cpu-type custom scale
    # rule needs an existing replica to sample and will not by itself lift
    # min_replicas = 0 back to 1 — whether combining it with min_replicas = 0
    # here is accepted at apply time, or silently never scales past zero,
    # could not be confirmed from within the environment this stack was
    # built in. If `terraform apply` rejects this combination, or worker
    # never leaves zero replicas under real backlog, the fix is either
    # bumping worker_min_replicas to 1 (variables.tf, same steady-cost
    # tradeoff the AWS stack's own worker_desired_count default makes) or
    # replacing this rule with a KEDA scaler type that documents scale-from-
    # zero support against an external metric — this worker's own
    # Redis-backed outbox relay depth is the natural one to reach for instead
    # of guessing at unverified CPU-rule behavior.
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

resource "azurerm_container_app" "web" {
  name                         = "${var.name_prefix}-web"
  container_app_environment_id = azurerm_container_app_environment.this.id
  resource_group_name          = azurerm_resource_group.this.name
  revision_mode                = "Single"

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.web.id]
  }

  registry {
    server   = azurerm_container_registry.this.login_server
    identity = azurerm_user_assigned_identity.web.id
  }

  # No secret blocks — web reads no secrets, mirroring execution_web's own
  # empty grant set (identity.tf).

  ingress {
    external_enabled           = false
    target_port                = 8080
    allow_insecure_connections = true
    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = var.web_min_replicas
    max_replicas = var.web_max_replicas

    container {
      name   = "web"
      image  = "${azurerm_container_registry.this.login_server}/web:${var.image_tag}"
      cpu    = var.web_cpu
      memory = var.web_memory

      env {
        name  = "MARGINCE_LOG_FORMAT"
        value = "json"
      }
    }

    # No custom_scale_rule — mirrors ecs.tf's own web service, left
    # un-autoscaled (static SPA/nginx, not CPU-bound the way api/worker are;
    # see the AWS stack's README for the same call). Container Apps applies
    # its own default HTTP-concurrency scale rule to any ingress-enabled app
    # with none declared explicitly, which is what moves this service between
    # web_min_replicas and web_max_replicas here.
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-web", Component = "compute-web" })
}
