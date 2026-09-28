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
    across (the Container Apps environment, Postgres Flexible Server's
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
  description = "Replicas of the api app. Each replica runs cmd/api plus the edge (nginx) container that serves the SPA and is the public entry, so this is also the web tier's replica count. Never scales to zero."
  type        = number
  default     = 2
}

variable "api_max_replicas" {
  type    = number
  default = 4
}

variable "worker_min_replicas" {
  description = <<-EOT
    Defaults to 1. worker runs River's periodic jobs (the 30-second capture
    sync dispatcher among them) and has no ingress, so nothing but its own
    CPU rule could wake it from zero, and a CPU rule has no replica to sample
    at zero (containerapps.tf's own comment). At 0, mailbox capture, AI jobs
    and every other background job would never run.
  EOT
  type        = number
  default     = 1
}

variable "worker_max_replicas" {
  type    = number
  default = 3
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
  description = "CPU of the edge (nginx + SPA) container inside the api app. api_cpu + web_cpu must, with the memory pair, form a valid Consumption combination."
  type        = number
  default     = 0.25
}

variable "web_memory" {
  description = "Memory of the edge container inside the api app (see web_cpu)."
  type        = string
  default     = "0.5Gi"
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

# ---- Public entry (the api app's edge container) ------------------------------------
# There is no gateway in front of this stack. The api app is the one app with
# external ingress, and its ingress targets the edge (nginx) container, which
# serves the SPA and forwards api paths to cmd/api on localhost
# (templates/edge-nginx.conf.tftpl).

variable "bind_custom_domain" {
  description = <<-EOT
    Binds public_base_url's host to the web app. Leave false on the FIRST
    apply: Container Apps refuses the binding until the domain's DNS already
    carries the asuid TXT record (value: the custom_domain_verification_id
    output) and a CNAME to the public_default_fqdn output, and neither exists
    before the environment does. Create both records, then set true and apply
    again. The managed certificate is issued afterwards by one
    `az containerapp hostname bind` call (README.md).
  EOT
  type        = bool
  default     = false
}

variable "break_glass_cidrs" {
  description = <<-EOT
    Source ranges allowed to use password login (POST /v1/auth/login). Every
    other client gets 403 from nginx, so staff can only sign in through Entra
    ID, where the customer's Conditional Access policy applies. Keep this to
    the one admin network that holds the break-glass account. Empty blocks
    password login for everyone.
  EOT
  type        = list(string)
  default     = []
}

variable "auth_rate_limit_per_minute" {
  description = "Requests per minute per client address that nginx allows on password login, password reset, OAuth token and first-run setup paths (burst of the same size). Staff behind one office NAT share one address, so keep headroom above the head count."
  type        = number
  default     = 30
}

variable "public_base_url" {
  description = "MARGINCE_PUBLIC_BASE_URL — e.g. https://crm.example.com. Its host is the custom domain bound to the web app, and the base of every Entra redirect URI."
  type        = string
  validation {
    condition     = can(regex("^https://[a-z0-9.-]+$", var.public_base_url))
    error_message = "public_base_url must be https://<host> with no path or trailing slash."
  }
}

# ---- Entra ID (the customer's existing tenant) ------------------------------------

variable "create_entra_app" {
  description = <<-EOT
    true: entra.tf creates the single-tenant app registration Margince signs
    staff in with (and captures mail through), requires assignment on its
    enterprise app, assigns entra_access_group_object_id to it, and seals a
    client secret into Key Vault. Needs the Terraform identity to hold
    Application Administrator in Entra.
    false: an Entra admin creates the app by hand (README.md) and passes
    entra_client_id and entra_client_secret instead.
  EOT
  type        = bool
  default     = true
}

variable "entra_access_group_object_id" {
  description = <<-EOT
    Object ID of the Entra security group allowed to use Margince. Reuse the
    group that already gates the customer's Dataverse environment, so one
    group membership decides access to both. Required when create_entra_app
    is true.
  EOT
  type        = string
  default     = ""
}

variable "entra_client_id" {
  description = "Application (client) ID of a hand-made app registration. Read only when create_entra_app is false."
  type        = string
  default     = ""
}

variable "entra_client_secret" {
  description = "Client secret of a hand-made app registration. Read only when create_entra_app is false."
  type        = string
  default     = ""
  sensitive   = true
}

variable "entra_secret_rotation_days" {
  description = "Lifetime of the client secret entra.tf creates. Terraform replaces it on the first apply after this many days; plan an apply before it expires."
  type        = number
  default     = 180
}

variable "entra_grant_admin_consent" {
  description = <<-EOT
    true grants tenant-wide admin consent for the delegated Microsoft Graph
    permissions entra.tf requests. Needs the Terraform identity to hold
    Privileged Role Administrator or Global Administrator. Leave false to have
    an Entra admin click "Grant admin consent" in the portal instead.
  EOT
  type        = bool
  default     = false
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

variable "enable_deep_monitoring" {
  description = <<-EOT
    Toggles alarms.tf's action group and metric alerts (Postgres CPU, Redis
    serverLoad) entirely. Log Analytics itself and every resource's own
    diagnostic settings stay on regardless — those are baseline "what
    happened" observability every deployment keeps, not the alerting layer
    this toggles. Off by default, same reasoning as the AWS stack's
    matching `enable_deep_monitoring`.
  EOT
  type        = bool
  default     = false
}

variable "alert_email" {
  description = <<-EOT
    Optional email address subscribed to alarms.tf's action group. Only
    read when enable_deep_monitoring is true. Left empty by default — an
    operator's alert destination is theirs to own, the same reasoning the
    AWS stack gives for not creating an SNS subscription itself (alarms.tf's
    own comment there). Azure's action group can hold this receiver
    directly rather than needing a separate `aws sns subscribe`-style step,
    so it is exposed as a variable instead.
  EOT
  type        = string
  default     = ""
}

# ---- Operator access and image builds -------------------------------------------

variable "operator_ip_allowlist" {
  description = <<-EOT
    Public IPv4 addresses (plain addresses, no /prefix) allowed through the
    public endpoints of Key Vault, the Storage Account and the container
    registry while you set the stack up or push images from a laptop
    (scripts/build-images.sh local). Each service keeps default-deny and its
    private endpoint; only these addresses are let in. Leave empty in steady
    state: the three services then have no public endpoint at all. Postgres
    and Redis are never reachable this way; use the jumpbox.
  EOT
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for ip in var.operator_ip_allowlist : can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", ip))])
    error_message = "operator_ip_allowlist takes plain IPv4 addresses such as 203.0.113.10 (Storage rejects /31 and /32 prefixes)."
  }
}

variable "enable_jumpbox" {
  description = <<-EOT
    Creates a small Linux VM inside the VNet (jumpbox.tf) with Docker, Azure
    CLI, Terraform and psql: the "cloud" image build path
    (scripts/build-images.sh cloud), the database bootstrap, and anything
    else that must reach the private endpoints. No public IP; reach it with
    Azure Bastion Developer (enable_bastion_developer) or
    `az vm run-command`. Shuts down every evening (jumpbox_shutdown_time).
  EOT
  type        = bool
  default     = true
}

variable "enable_bastion_developer" {
  description = "Adds Azure Bastion's free Developer tier for browser SSH to the jumpbox from the Azure portal. Read only when enable_jumpbox is true."
  type        = bool
  default     = true
}

variable "jumpbox_vm_size" {
  description = "2 vCPU / 8 GiB builds the Go and web images in a few minutes. Billed only while running."
  type        = string
  default     = "Standard_B2ms"
}

variable "jumpbox_admin_username" {
  type    = string
  default = "margince"
}

variable "jumpbox_ssh_public_key" {
  description = "OpenSSH public key for jumpbox_admin_username. Password login is disabled. Required when enable_jumpbox is true."
  type        = string
  default     = ""
}

variable "jumpbox_shutdown_time" {
  description = "Daily automatic shutdown, HHMM in jumpbox_shutdown_timezone. Start it again with `az vm start` or scripts/build-images.sh cloud."
  type        = string
  default     = "2000"
}

variable "jumpbox_shutdown_timezone" {
  type    = string
  default = "W. Europe Standard Time"
}

# ---- Attachments ---------------------------------------------------------------

variable "attachments_share_quota_gb" {
  description = <<-EOT
    Size of the Azure Files share mounted read-write into api and worker as
    MARGINCE_BLOBSTORE_PATH (Margince's filesystem attachment store), until a
    native Azure Blob adapter exists. Billed on use, not quota.
  EOT
  type        = number
  default     = 100
}
