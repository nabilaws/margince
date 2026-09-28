# Margince on Azure

Container Apps (api with its edge container, worker), Postgres Flexible Server, Azure Cache for
Redis, a Storage Account (blob container + Azure Files share), Key Vault, one
customer-managed key, and an Entra ID app registration in the customer's
tenant. There is no gateway and no separate web app: the `api` app's ingress
targets an `edge` nginx container (built from the web image, so it carries the
SPA) that runs beside `cmd/api` in each replica and forwards api paths to it on
localhost (`templates/edge-nginx.conf.tftpl`). Staff sign in with Microsoft only; password login is limited to
`break_glass_cidrs`. See the [shared README](../README.md) for the
cross-cloud design notes and what is deliberately out of scope (autoscaling
tuning beyond a floor/ceiling, multi-region/HA, DR runbooks).

**Attachments** are stored with Margince's filesystem provider on an Azure
Files share mounted read-write at `/app/blobstore` (`MARGINCE_BLOBSTORE_PATH`),
because the product's object-store client speaks S3 only and Azure Blob
Storage does not (`storage.tf`). A native Azure Blob adapter would replace it.

**Where to run things.** Key Vault, Storage and the registry have no public
endpoint in steady state, and Postgres never has one. During setup,
`operator_ip_allowlist` opens the first three to your own public IP (so
Terraform, image pushes and the config upload work from a laptop), and the
jumpbox (`jumpbox.tf`, a small VM inside the VNet with no public IP) covers
what must reach Postgres, plus the cloud image build. Remove your IP from the
allowlist when setup is done.

## 1. Provision

Use a remote state backend (uncomment the `backend "azurerm"` block in
`versions.tf`): state holds every generated password and the Entra client
secret, and the jumpbox may need to read outputs too.

```bash
cd deploy/terraform/azure
cp terraform.tfvars.example terraform.tfvars
#   public_base_url, admin_bootstrap_password, image_tag,
#   entra_access_group_object_id, break_glass_cidrs,
#   operator_ip_allowlist = ["$(curl -s https://api.ipify.org)"],
#   jumpbox_ssh_public_key = "<contents of ~/.ssh/id_ed25519.pub>"
terraform init

# Everything except the Container Apps first: they reference image_tag, which
# nothing has pushed yet.
terraform apply \
  -target=azurerm_key_vault_secret.entra_client_secret \
  -target=azurerm_key_vault_secret.license \
  -target=azurerm_container_registry.this \
  -target=azurerm_postgresql_flexible_server.this -target=azurerm_redis_cache.this \
  -target=azurerm_storage_share.config -target=azurerm_storage_share.attachments \
  -target=azurerm_linux_virtual_machine.jumpbox -target=azurerm_bastion_host.developer \
  -target=azurerm_role_assignment.jumpbox_acr_push
```

This creates the VNet, NAT, Key Vault (with its key and secrets), Postgres,
Redis, the Storage Account and shares, the registry, the Entra app, and the
jumpbox with Bastion Developer. Do steps 2–5 next, then run a final
untargeted `terraform apply` with `bind_custom_domain = false` to create the
Container Apps. Step 6 binds the domain.

## 2. Entra ID (once)

The Terraform identity needs Entra's **Application Administrator** role to
create the app registration (`create_entra_app = true`, the default). If the
customer will not grant that, an Entra admin creates the app by hand with the
redirect URIs from `terraform output entra_redirect_uris`, the delegated
Microsoft Graph permissions listed in `entra.tf`, and a client secret, then
sets `create_entra_app = false`, `entra_client_id` and `entra_client_secret`.

After the apply that creates the app, an Entra admin:

1. Grants admin consent for the Graph permissions (Enterprise applications →
   Margince → Permissions), unless `entra_grant_admin_consent = true`.
2. Adds the app (`terraform output -raw entra_client_id`) to the Conditional
   Access policy that already protects Dataverse, so MFA and device rules are
   identical for both.
3. Confirms "Assignment required" is on and the Dataverse security group is
   the only assignment.

The client secret rotates on the first apply after
`entra_secret_rotation_days`; schedule an apply before it lapses.

## 3. Bootstrap the database (once)

Postgres is reachable only from inside the VNet, so run this **on the
jumpbox**: Azure portal → the jumpbox VM → Connect → Bastion (SSH, private
key), then `az login`, clone the repo (step 4, cloud build) and run the
commands below from `deploy/terraform/azure` with the same remote state.

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

## 4. Build and push the images

Two ways, same result in the registry. `<tag>` must equal `image_tag`.

**On your Mac** (Docker with buildx; Colima works):

```bash
colima start                          # if not running
scripts/build-images.sh local <tag>   # asks: 1) x86 (amd64)  2) ARM (arm64)
```

- **x86 (amd64)** (`scripts/build-local-amd64.sh`) is what Azure runs:
  Container Apps requires `linux/amd64` images. It cross-builds (Go and the
  SPA compile natively, only the runtime stages run under emulation) and
  pushes to the registry, so your IP must be in `operator_ip_allowlist`.
- **ARM (arm64)** (`scripts/build-local-arm64.sh`) builds natively for running
  on the Mac, loaded locally as `margince/<role>:<tag>-arm64`. `--push` uploads
  them as `<tag>-arm64`; they never replace the deployable tag.
- `--arch amd64` or `--arch arm64` skips the question.

**In Azure, on the jumpbox** (native x86, pushes over the private endpoint
with the VM's managed identity, no allowlist needed). Once, over Bastion SSH:

```bash
gh auth login        # or install a read-only deploy key
git clone <margince repo URL> /opt/margince
```

Then from your Mac, for every build:

```bash
scripts/build-images.sh cloud <tag> [git_ref]   # starts the VM if stopped
```

The build runs through `az vm run-command`, so it needs no SSH and no public
IP. The jumpbox shuts down every evening (`jumpbox_shutdown_time`).

## 5. Write `margince.yaml` onto the config share (once)

With your IP in `operator_ip_allowlist`, upload it from your Mac:

```bash
STORAGE_ACCOUNT="$(terraform output -raw storage_account_name)"
STORAGE_KEY="$(az storage account keys list --account-name "$STORAGE_ACCOUNT" --query '[0].value' -o tsv)"
cp ../../../config/margince.example.yaml margince.yaml
# edit margince.yaml: workspace, bootstrap_admin (password_file:
# secrets/admin-password, the api's working dir is /app), seeds.ai_routing
az storage file upload --account-name "$STORAGE_ACCOUNT" --account-key "$STORAGE_KEY" \
  --share-name "<name_prefix>-config" --source margince.yaml --path margince.yaml
rm margince.yaml
```

When setup is finished, set `operator_ip_allowlist = []` and apply: Key Vault,
Storage and the registry go back to private endpoints only.

## 6. DNS, certificate + first boot

The custom domain is bound in two passes, because Container Apps checks DNS
before it accepts the binding:

```bash
# 1. DNS records (in the customer's zone)
#    CNAME  crm.example.com        -> $(terraform output -raw public_default_fqdn)
#    TXT    asuid.crm.example.com  -> $(terraform output -raw custom_domain_verification_id)

# 2. Bind the hostname
terraform apply -var bind_custom_domain=true   # or set it in terraform.tfvars

# 3. Issue and bind the free managed certificate (azurerm ~> 3.117 cannot).
#    Use --validation-method HTTP (and an A record to environment_static_ip)
#    if the host is a zone apex. If the zone has a CAA record, it must allow
#    DigiCert: 0 issue digicert.com. Keep the api app running: renewals need it.
az containerapp hostname bind -g <resource-group> -n <name_prefix>-api \
  --hostname crm.example.com --environment <name_prefix>-env --validation-method CNAME
```

Once `https://<host>/healthz` answers through the edge container, the api has applied
migrations and bootstrapped the organization from `MARGINCE_ADMIN_PASSWORD`.
Per `docs/deployment.md`, then remove `bootstrap_admin` from `margince.yaml`
and rotate the `admin-password` secret to something inert. Staff accounts are
invited in Margince with the same email address they have in Entra; Microsoft
sign-in links to them on first login.

## Moving from the Application Gateway layout

`internal_load_balancer_enabled` cannot change in place, so applying this
version over the gateway layout replaces the Container Apps environment and
all three apps. Postgres, Redis, Storage and Key Vault are untouched. Expect
downtime from the apply until DNS points at the new api app; schedule it, or
build the new environment under a different `name_prefix` first and switch
DNS once it answers.

## 7. Releasing a new version

Build/push new images tagged with the release version, set `image_tag` to
that version, `terraform apply`. All three Container Apps pick up the new
revision on the same apply (web ships inside the api app's edge container), the same "api/worker/web move together" release
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
| Client → api app (edge container) | TLS at the environment's edge with a free managed certificate; HTTP redirects to HTTPS (`allow_insecure_connections = false`) |
| edge (nginx) → cmd/api | Plaintext HTTP on localhost inside one replica — `cmd/api` serves plain HTTP and expects TLS to end ahead of it, same as the AWS stack's ALB→ECS hop. `cmd/api`'s port is never exposed by the ingress |
| Task → Postgres | `require_secure_transport = ON` (server refuses plaintext) + `sslmode=verify-full` on both DSNs — encrypted and authenticated against Postgres Flexible Server's public CA chain, no separate CA bundle to distribute (unlike RDS) |
| Task → Redis | `minimum_tls_version = "1.2"`, `enable_non_ssl_port = false` — no plaintext port exists to fall back to at all |
| Task → Storage (config share) | Azure Files over SMB 3.0 with encryption in transit is the default for this account's minimum TLS setting; the mount command in step 5 passes `vers=3.0` accordingly |

**Other hardening**: Key Vault, ACR, the Storage Account, and Redis all set
`public_network_access_enabled = false` and are reachable only through
`privateendpoints.tf`'s private endpoints, on the one shared
`private_endpoints` subnet (`network.tf`); ACR is Premium tier specifically
because it is the only tier supporting both a private endpoint and a
customer-managed key (`acr.tf`'s own comment); only the `api` app has
external ingress and it targets the `edge` container, never `cmd/api` itself;
`worker` has no ingress — it blocks password login outside `break_glass_cidrs`,
rate limits auth paths per real client address, and keeps `/metrics`
private; staff sign-in goes through the customer's Entra tenant (`entra.tf`),
restricted to one security group by "assignment required" and covered by
their Conditional Access policy; api/worker share one user-assigned identity
(`identity.tf`) scoped to Key Vault Secrets User + AcrPull, plus the
`dataverse` identity that holds no Azure role. The edge container runs in the
api app, so it shares that app's identities: it cannot read `cmd/api`'s
environment or secrets, but a compromised nginx could request the same tokens.
That is the price of dropping the separate web app and its Host rewrite;
keep the edge image patched with each release; Key Vault uses `rbac_authorization_enabled =
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
- **Attachments use Azure Files, not Blob Storage** — see this file's own top section. Upload and read back one attachment after the first deploy.
- **No managed WAF rule set.** The gateway's OWASP rules were removed to save
  ~€475/month; the exposed surface is the edge container's nginx, Entra-only staff sign-in
  and token-protected guest links. Add Azure Front Door Standard in front of
  web if edge DDoS absorption or country filtering becomes a requirement.
- **The nginx config is a copy.** `templates/edge-nginx.conf.tftpl` replaces
  `frontend/nginx.conf` for this deployment; keep their SPA locations in step.
- **cmd/api sees every request from 127.0.0.1.** Its own per-address rate
  limits therefore share one bucket per replica; the edge's `limit_req` on the
  auth paths uses the real client address instead. Closing this in the app
  means trusting X-Forwarded-For from localhost.

**Left out, deliberately** (see the [shared README](../README.md)):
autoscaling tuning beyond a floor/ceiling, multi-region/HA, and DR runbooks.
Each is a real deployment decision, not a default this reference should pick.
