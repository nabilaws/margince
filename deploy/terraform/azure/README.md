# Margince on Azure

Container Apps (api, worker, web), Postgres Flexible Server, Azure Cache for
Redis, a Storage Account (blob container + Azure Files share), Key Vault, one
customer-managed key, one Application Gateway (WAF_v2) fronted by an OWASP
managed-rule WAF policy. See the [shared README](../README.md) for the
cross-cloud design notes and what is deliberately out of scope (autoscaling
tuning beyond a floor/ceiling, multi-region/HA, DR runbooks).

**Known gap, read first**: this stack does NOT wire up object storage for the
product's blobstore feature. Azure Storage accounts speak their own native
REST API, not S3's — the product's blobstore client
(`backend/internal/platform/blobstore/s3.go`) is a generic `minio-go` client
that only speaks S3. `storage.tf` provisions the Storage Account correctly (a
private, CMK-encrypted, versioned blob container) but `containerapps.tf`
deliberately leaves `MARGINCE_BLOBSTORE_*` unset — there is nothing correct to
point it at yet. Closing this needs a second Go-side adapter
(`azureblob.Store`, using the Azure Blob SDK) that has not been built. This is
known and out of scope for this Terraform change, not a silent omission.

## 1. Provision

```bash
cd deploy/terraform/azure
cp terraform.tfvars.example terraform.tfvars   # fill in public_base_url, admin_bootstrap_password, image_tag
terraform init
terraform plan

# Everything EXCEPT Application Gateway and the 3 Container Apps first — the
# gateway's ssl_certificate references a Key Vault secret ID
# (tls_certificate_key_vault_secret_id) that only exists once the vault does,
# and the apps reference image_tag, which nothing has pushed yet.
terraform apply \
  -target=azurerm_key_vault.this -target=azurerm_container_registry.this \
  -target=azurerm_postgresql_flexible_server.this -target=azurerm_redis_cache.this \
  -target=azurerm_storage_account.this
```

This creates the VNet, Key Vault, Postgres Flexible Server, Redis cache,
Storage Account, and ACR. Do steps 2–4 next — import the TLS certificate,
bootstrap the database, push the images, write `margince.yaml` onto the
config share — then run a final untargeted `terraform apply` to create the
Application Gateway and the 3 Container Apps, which by then have a
certificate, an image to pull, and a database to migrate against.

## 2. Import the TLS certificate (once)

```bash
az keyvault certificate import --vault-name "$(terraform output -raw key_vault_uri | sed -E 's#https://([^.]+).*#\1#')" \
  -n tls-cert -f your-cert.pfx
```

Set `tls_certificate_key_vault_secret_id` in `terraform.tfvars` to the
versionless secret ID this prints, then re-run `terraform apply`.

## 3. Bootstrap the database (once)

Postgres Flexible Server's admin login is `pgadmin` (see `postgres.tf` for why
it is not named `margince_owner`) — Azure grants this login a broad,
non-superuser privilege set (create role, create database, use any
server-allow-listed extension) rather than true `rds_superuser`/superuser,
which is enough to run `scripts/deploy/db-bootstrap.sql` but is a materially
different admin model from RDS's, not just a renamed equivalent:

- **The `margince` database does not already exist here.** RDS's own
  `db_name` argument (`aws/rds.tf`) provisions the application database at
  create time; Postgres Flexible Server has no equivalent argument — it only
  ever provisions the default `postgres` database. `db-bootstrap.sql`'s own
  `CREATE DATABASE margince OWNER margince_owner` branch, written as a
  no-op-if-exists guard for the AWS path, actually RUNS on this path instead
  of being skipped.
- **Extensions must be server-allow-listed before `CREATE EXTENSION` will
  succeed at all**, even for `pgadmin` — `postgres.tf`'s
  `azurerm_postgresql_flexible_server_configuration.azure_extensions` sets
  this (`VECTOR,UNACCENT,PG_TRGM,BTREE_GIST`), and its `depends_on` on the
  server resource makes sure that configuration lands before this step runs.
  RDS's master user can install an allow-listed extension directly with no
  separate control-plane grant; Azure requires both.
- **No superuser exists on this platform at all** — `pgadmin`'s privilege set
  is the platform's own ceiling, not a renamed superuser role. The
  bootstrap script's own reasoning ("a superuser ignores every grant, so the
  wall between what serves traffic and what applies DDL exists only while
  neither role is exempt") holds at least as well here as on RDS, since there
  is no more-privileged role for `margince_owner`/`margince_app` to
  accidentally collide with in the first place.

```bash
OWNER_PW="$(terraform output -json 2>/dev/null; az keyvault secret show --vault-name <vault> -n margince-owner-dsn --query value -o tsv | sed -E 's#.*:([^:@]+)@.*#\1#')"
APP_PW="$(az keyvault secret show --vault-name <vault> -n margince-dsn --query value -o tsv | sed -E 's#.*:([^:@]+)@.*#\1#')"
ADMIN_PW="$(terraform state show random_password.postgres_admin | grep 'result ' | awk '{print $3}' | tr -d '"')"

psql "postgres://pgadmin:${ADMIN_PW}@$(terraform output -raw postgres_fqdn):5432/postgres?sslmode=verify-full" \
  -v owner_pw="$OWNER_PW" -v app_pw="$APP_PW" \
  -f ../../../scripts/deploy/db-bootstrap.sql
```

(`az postgres flexible-server show` never returns the admin password; it only
exists as this Terraform-generated value. `sslmode=verify-full` needs no
`sslrootcert` here — Flexible Server's certificate chains to DigiCert Global
Root G2, a public root most client trust stores already carry, unlike RDS's
own private CA bundle.)

## 4. Push the three images

```bash
IMAGE_TAG="<the same value you set for image_tag in terraform.tfvars>"

az acr login --name "$(terraform output -raw acr_login_server | cut -d. -f1)"

for role in api worker web; do
  docker buildx build --target "$role" \
    -t "$(terraform output -json acr_repository_names | jq -r .$role):${IMAGE_TAG}" --push .
done
```

`IMAGE_TAG` must equal `var.image_tag` exactly. Unlike the AWS stack's
`IMMUTABLE` ECR repos, ACR does not refuse a re-push to the same tag
(`acr.tf`'s own comment) — picking a real release identifier here is a
release-discipline convention this stack asks of you, not something the
registry enforces.

## 5. Write `margince.yaml` onto the config share (once)

Terraform provisions the Azure Files share; it does not write into it. From
any machine with network access to the storage account (this account's
`public_network_access_enabled = false`, so a VPN/bastion/VNet-peered host is
required — the same constraint the private endpoint in
`privateendpoints.tf` exists to enforce):

```bash
STORAGE_ACCOUNT="$(terraform output -raw storage_account_name)"
STORAGE_KEY="$(az storage account keys list --account-name "$STORAGE_ACCOUNT" --query '[0].value' -o tsv)"

sudo mount -t cifs "//${STORAGE_ACCOUNT}.file.core.windows.net/${STORAGE_ACCOUNT%data}-config" /mnt/margince-config \
  -o username="${STORAGE_ACCOUNT}",password="${STORAGE_KEY}",serverino,vers=3.0

sudo cp config/margince.example.yaml /mnt/margince-config/margince.yaml
# edit /mnt/margince-config/margince.yaml — set password_file to
# secrets/admin-password (the api's working dir is /app) per docs/deployment.md
sudo umount /mnt/margince-config
```

## 6. DNS + first boot

Point `public_base_url`'s host at `terraform output -raw appgw_fqdn` (a CNAME)
or `terraform output -raw appgw_public_ip` (an A record) — the FQDN exists
only because `appgateway.tf`'s public IP requests one via
`domain_name_label`; a bare Azure public IP has no DNS name of its own the
way an ALB's own `dns_name` always does. Once the api Container App can reach a
healthy `/healthz` through the gateway, it applies migrations and bootstraps
the organization from `MARGINCE_ADMIN_PASSWORD` — after which, per
`docs/deployment.md`, remove `bootstrap_admin` from `margince.yaml` and rotate
the `admin-password` secret to something inert.

## 7. Releasing a new version

Build/push new images tagged with the release version, set `image_tag` to
that version, `terraform apply`. All three Container Apps pick up the new
revision on the same apply, the same "api/worker/web move together" release
guard `docs/deployment.md` describes for the AWS stack.

## Security posture

**Encryption at rest** — one customer-managed key (`keyvault.tf`'s
`azurerm_key_vault_key.data`, 2-year rotation) covers Postgres, the Storage
Account, and ACR (`postgres.tf`, `storage.tf`, `acr.tf`'s own
`customer_managed_key`/`encryption` blocks, all through the one shared
grant-holder identity in `identity.tf`). **Redis is the one deliberate
exception** — Azure Cache for Redis's customer-managed-key support is
Premium-tier only, and this stack defaults to Standard (see `redis.tf`'s own
comment for the cost/capability tradeoff that decision rests on). Redis still
gets Microsoft-managed encryption at rest regardless — what's missing is only
the customer key, not encryption itself.

**Encryption in transit**:

| Hop | Enforcement |
|---|---|
| Client → Application Gateway | TLS via the imported certificate (`ssl_certificate`), HTTP redirects to HTTPS |
| Application Gateway → api/web Container Apps | Plaintext HTTP inside the VNet — matches the product's own architecture, same as the AWS stack's ALB→ECS hop: `cmd/api` serves plain HTTP and terminates TLS ahead of itself |
| Task → Postgres | `require_secure_transport = ON` (server refuses plaintext) + `sslmode=verify-full` on both DSNs — encrypted and authenticated against Postgres Flexible Server's public CA chain, no separate CA bundle to distribute (unlike RDS) |
| Task → Redis | `minimum_tls_version = "1.2"`, `enable_non_ssl_port = false` — no plaintext port exists to fall back to at all |
| Task → Storage (config share) | Azure Files over SMB 3.0 with encryption in transit is the default for this account's minimum TLS setting; the mount command in step 5 passes `vers=3.0` accordingly |

**Other hardening**: Key Vault, ACR, the Storage Account, and Redis all set
`public_network_access_enabled = false` and are reachable only through
`privateendpoints.tf`'s private endpoints, on the one shared
`private_endpoints` subnet (`network.tf`); ACR is Premium tier specifically
because it is the only tier supporting both a private endpoint and a
customer-managed key (`acr.tf`'s own comment); Container Apps run with
`internal_load_balancer_enabled = true` on their environment, so — like the
AWS stack's ECS tasks having no public IP — the Application Gateway is this
stack's one public entry point; api/worker and web each get their own
user-assigned identity (`identity.tf`), api/worker's scoped to Key Vault
Secrets User + AcrPull, web's to AcrPull only, mirroring the AWS stack's own
execution/execution_web split; Key Vault uses `rbac_authorization_enabled =
true` rather than the legacy access-policy model, so every grant in this
stack is an ordinary `azurerm_role_assignment`, not a second permission model
to keep in step.

**Known, documented gaps versus the AWS stack** (stated here, not worked
around):

- **ACR has no `IMMUTABLE`-tag equivalent and no "keep only N tagged images"
  lifecycle rule** — only untagged-manifest expiry (`acr.tf`'s own comment).
  An operator wanting AWS-equivalent tag immutability does it by hand today.
- **api/worker's identity can pull web's image and vice versa** — ACR's
  repository-scoped RBAC (`role_assignment_mode = "AbacRepositoryPermissions"`)
  exists but its exact condition syntax and GA maturity could not be verified
  from within the environment this stack was built in (`identity.tf`'s own
  comment); this is a real, deliberate regression from the AWS stack's
  per-repository IAM scoping, not a hidden one.
- **No VPC/VNet-flow-log equivalent to the AWS stack's `aws_flow_log.this`**
  — Azure stopped accepting new NSG-scoped flow logs on June 30, 2025 (the
  only scope this stack's pinned `azurerm` provider line, `~> 3.117`,
  actually supports — its VNet-scoped replacement needs the provider's 4.x
  line, a wider migration this change does not fold in). `network.tf`'s own
  comment on `azurerm_network_watcher.this` has the full reasoning and the
  upgrade path.
- **No blobstore adapter** — see this file's own top section.
- **appgateway.tf's path patterns are a best-effort port** of `alb.tf`'s own
  ALB wildcard syntax to Application Gateway's — verify each `path_rule`
  against a real request before relying on it.
- **CPU-credit alarms have no literal Azure equivalent** — `alarms.tf`
  watches `cpu_percent` (Postgres) and `serverLoad` (Redis) instead; see that
  file's own top comment for why neither platform exposes a credit-balance
  metric the way AWS's T-family burstable instances do.
- **Worker's scale-from-zero is unverified** — `containerapps.tf`'s own
  comment on `azurerm_container_app.worker`'s `custom_scale_rule` states
  plainly that a cpu-type KEDA rule combined with `min_replicas = 0` was not
  confirmed against a live environment; if it does not behave as intended,
  the fix is bumping `worker_min_replicas` to 1 or moving to a scaler that
  documents scale-from-zero support (a Redis-stream-depth scaler, given
  worker's own outbox relay, is the natural one to reach for).

**Left out, deliberately** (see the [shared README](../README.md)):
autoscaling tuning beyond a floor/ceiling, multi-region/HA, and DR runbooks.
Each is a real deployment decision, not a default this reference should pick.
