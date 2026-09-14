variable "azure_region" {
  description = <<-EOT
    Azure region every resource is created in. Defaults to "westeurope"
    rather than "germanywestcentral" (the closer geographic match to the AWS
    stack's own eu-central-1/Frankfurt default) because West Europe has the
    longest-established, broadest support for every service this stack uses —
    Container Apps, Premium ACR with a customer-managed key, Postgres Flexible
    Server zone-redundant HA. An operator with a Germany-specific
    data-residency requirement should override this, after confirming each
    service used here is generally available in that region too.
  EOT
  type        = string
  default     = "westeurope"
}

variable "resource_group_name" {
  description = "Name of the resource group every resource in this stack is created in."
  type        = string
  default     = "margince"
}

variable "name_prefix" {
  description = "Short prefix for every resource name (e.g. \"margince-prod\")."
  type        = string
  default     = "margince"
}

variable "environment" {
  description = <<-EOT
    Stamped onto every resource's Environment tag (network.tf's local.common_tags)
    — the dimension a cost/operations tool groups this stack's spend and
    automation by when the same name_prefix is reused across more than one
    environment (a staging copy of "margince", say).
  EOT
  type        = string
  default     = "production"
}

variable "vnet_cidr" {
  description = "Address space for the virtual network this stack creates."
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_count" {
  description = <<-EOT
    Number of Availability Zones this stack's zone-redundant resources spread
    across (Application Gateway's own `zones`, Postgres Flexible Server's
    ZoneRedundant high availability mode). Unlike the AWS stack's az_count,
    this does NOT size a per-zone subnet/route-table pair — Azure subnets are
    regional, not zone-scoped, so one public and one private subnet cover
    every zone already; only the resources placed in them are zone-pinned.
    See network.tf's own comment on what that means for NAT egress
    resilience specifically.
  EOT
  type        = number
  default     = 2
  validation {
    condition     = var.az_count >= 2
    error_message = "az_count must be at least 2 — Postgres Flexible Server's ZoneRedundant HA mode needs a primary and a standby zone."
  }
}

# ---- Images ---------------------------------------------------------------

variable "image_tag" {
  description = <<-EOT
    Tag to deploy for all three roles (api, worker, web) — a real release
    version (e.g. a git SHA or MARGINCE_RELEASE_VERSION), never "latest".
    Unlike the AWS stack's ECR repos (image_tag_mutability = IMMUTABLE), ACR
    has no Terraform-managed equivalent that refuses a re-push to the same
    tag — see acr.tf's own comment for why. This variable's "no latest" rule
    is therefore a release-discipline convention this stack asks of you, not
    something the registry itself enforces the way ECR does on AWS. No
    default: picking a floating tag is an operator decision this stack should
    not make silently.
  EOT
  type        = string
  validation {
    condition     = length(trimspace(var.image_tag)) > 0
    error_message = "image_tag must not be empty or whitespace."
  }
}

# ---- Compute sizing ---------------------------------------------------------
# Container Apps has no cpu_architecture knob the way Fargate's
# runtime_platform does — the platform does not expose an Arm64/x86_64 choice
# to select at all, so there is nothing here to mirror from the AWS stack's
# own var.cpu_architecture.

variable "api_min_replicas" {
  description = "api must stay warm behind the Application Gateway — unlike worker, it never scales to zero."
  type        = number
  default     = 2
}

variable "api_max_replicas" {
  type    = number
  default = 4
}

variable "worker_min_replicas" {
  description = <<-EOT
    Defaults to 0 — worker has no ingress behind it (it only drains the
    outbox relay), so idle-cost is worth trading for a cold start: KEDA scales
    it back up from zero once the custom_scale_rule (containerapps.tf) sees
    CPU pressure or, if nothing is running, on the next poll interval. The
    tradeoff is real: a backlog that arrives while worker is at zero waits
    one cold-start (image pull is skipped since it's already cached on the
    platform, but the container still boots + connects to Postgres/Redis)
    before the first event drains. Set to 1 to keep it warm like AWS's own
    worker_desired_count default, at the steady per-replica cost that implies.
  EOT
  type        = number
  default     = 0
}

variable "worker_max_replicas" {
  type    = number
  default = 3
}

variable "web_min_replicas" {
  type    = number
  default = 2
}

variable "web_max_replicas" {
  type    = number
  default = 4
}

# vCPU/memory pairs must add up to one of Container Apps' fixed Consumption
# combinations (learn.microsoft.com/azure/container-apps/containers#allocations)
# — these three pairs are each a valid combination, chosen to size closest to
# the AWS stack's own api_cpu=512/api_memory=1024 (0.5 vCPU : 1GiB is exactly
# that ratio; Fargate's own units are 1024ths of a vCPU, Container Apps' are
# whole/fractional vCPUs).
variable "api_cpu" {
  type    = number
  default = 0.5
}

variable "api_memory" {
  type    = string
  default = "1Gi"
}

variable "worker_cpu" {
  type    = number
  default = 0.5
}

variable "worker_memory" {
  type    = string
  default = "1Gi"
}

variable "web_cpu" {
  type    = number
  default = 0.25
}

variable "web_memory" {
  type    = string
  default = "0.5Gi"
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "acr_untagged_manifest_retention_days" {
  description = <<-EOT
    acr.tf's retention_policy_in_days — expires an UNTAGGED manifest (the
    previous digest, once a tag moves) after this many days. Mirrors the AWS
    stack's own untagged-image cleanup (ecs.tf's 14-day rule); unlike ECR,
    ACR has no "keep only the N most recent TAGGED images" lifecycle rule to
    mirror the AWS stack's ecr_tagged_image_retain_count with — see acr.tf's
    own comment for why that half of the AWS cleanup policy does not port.
  EOT
  type        = number
  default     = 14
}

# ---- Database ---------------------------------------------------------------

variable "db_sku_name" {
  description = <<-EOT
    Postgres Flexible Server SKU, "tier_Family+size" — B_Standard_B2s (2 vCPU,
    4GiB) rather than B_Standard_B1ms (1 vCPU, 2GiB): the closer match to the
    AWS stack's own db.t4g.medium default (2 vCPU, 4GiB), and still the
    cheapest Burstable size that hits it.
  EOT
  type        = string
  default     = "B_Standard_B2s"
}

variable "db_storage_mb" {
  description = <<-EOT
    Postgres Flexible Server only accepts storage_mb from a fixed list
    (documented on azurerm_postgresql_flexible_server) — 65536 (64 GiB) is the
    smallest value on that list at or above the AWS stack's own
    db_allocated_storage_gb default of 50 GiB.
  EOT
  type        = number
  default     = 65536
}

variable "db_version" {
  description = "Postgres major version. Must be a version Azure lists pgvector support for."
  type        = string
  default     = "16"
}

variable "db_zone_redundant_ha" {
  description = <<-EOT
    Feeds postgres.tf's high_availability.mode = "ZoneRedundant" — Azure's
    equivalent of the AWS stack's own db_multi_az (one standby, in a
    different zone, promoted automatically on primary failure). Azure has no
    finalizer-name pattern to mirror from the AWS stack's own
    db_final_snapshot_generation/random_id.final_snapshot — Postgres Flexible
    Server does not require (or accept) a named final snapshot on delete, so
    that variable and its keepers-based random_id simply do not port; see
    postgres.tf's own comment.
  EOT
  type        = bool
  default     = true
}

variable "db_backup_retention_days" {
  type    = number
  default = 7
}

# ---- Redis ------------------------------------------------------------------

variable "redis_sku_name" {
  description = <<-EOT
    "Standard", not "Basic" or "Premium" — Basic has no replica and no SLA at
    all (a single-node cache with no failover is a worse durability posture
    than this stack should default to for something acting as an outbox
    relay, even a lossily-tolerant one); Premium is the tier ElastiCache-style
    node redundancy on AWS costs nothing extra for, but on Azure jumps ~10x
    for capabilities (VNet injection, a customer-managed key) this stack does
    not need for Redis specifically — see redis.tf's own comment. Standard's
    built-in replica is the honest middle: real failover, at Basic-adjacent
    cost.
  EOT
  type        = string
  default     = "Standard"
}

variable "redis_capacity" {
  description = "Redis SKU capacity within the C (Basic/Standard) family — 1 is the C1 size (1 GiB), the smallest Standard offers."
  type        = number
  default     = 1
}

# ---- Routing ------------------------------------------------------------------

variable "appgw_min_capacity" {
  description = "Floor for appgateway.tf's autoscale_configuration — the closest Application Gateway equivalent to ecs.tf's api_desired_count, though the platform sizes Capacity Units on its own rather than taking a CPU-tracking policy."
  type        = number
  default     = 2
}

variable "appgw_max_capacity" {
  description = "Ceiling for appgateway.tf's autoscale_configuration."
  type        = number
  default     = 10
}

variable "tls_certificate_key_vault_secret_id" {
  description = <<-EOT
    Versionless Key Vault secret ID of a PFX certificate covering the public
    host this installation serves (MARGINCE_PUBLIC_BASE_URL's host), already
    imported into this stack's Key Vault (keyvault.tf) — e.g.
    "https://<vault>.vault.azure.net/secrets/tls-cert". Not created by this
    stack, the same reasoning the AWS stack gives for var.acm_certificate_arn:
    validating a certificate needs the domain's own DNS, which lives wherever
    the operator's zone lives. Import with:
      az keyvault certificate import --vault-name <vault> -n tls-cert -f cert.pfx
  EOT
  type        = string
}

variable "public_base_url" {
  description = "MARGINCE_PUBLIC_BASE_URL — e.g. https://crm.example.com"
  type        = string
}

# ---- Secrets and application config -----------------------------------------

variable "license_token" {
  description = "MARGINCE_LICENSE. Empty runs unlicensed, which a production role refuses to boot on."
  type        = string
  default     = ""
  sensitive   = true
}

variable "admin_bootstrap_password" {
  description = <<-EOT
    MARGINCE_ADMIN_PASSWORD for the first boot against an empty database.
    Rotate/remove per docs/deployment.md once the organization exists — this
    variable only seeds the initial secret version.
  EOT
  type        = string
  sensitive   = true
}

variable "alert_email" {
  description = <<-EOT
    Optional email address subscribed to alarms.tf's action group. Left empty
    by default — an operator's alert destination is theirs to own, the same
    reasoning the AWS stack gives for not creating an SNS subscription itself
    (alarms.tf's own comment there). Azure's action group can hold this
    receiver directly rather than needing a separate `aws sns subscribe`-style
    step, so it is exposed as a variable instead.
  EOT
  type        = string
  default     = ""
}
