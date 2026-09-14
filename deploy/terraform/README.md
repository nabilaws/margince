# Terraform: cloud deployment stacks

Deployment-target Terraform root modules — one per cloud — that stand up a
complete Margince installation: the three role images (`api`, `worker`,
`web`), a managed Postgres with `pgvector`, managed Redis, object storage, a
secrets store with customer-managed encryption, and one routed host in front
of `api` + `web` per the table in
[`docs/deployment.md`](../../docs/deployment.md#routing).

**AWS** ([`aws/README.md`](aws/README.md)) and **Azure**
([`azure/README.md`](azure/README.md)) are both built. GCP is not built yet —
this is deliberately not GCP-only-never; a later PR adds
`deploy/terraform/gcp/` following the same shape. The Azure stack has its own
documented gaps versus the AWS one (no blobstore adapter yet, ACR's weaker
tag-immutability/scoping story) — see `azure/README.md`'s own "Known,
documented gaps" section rather than assuming full parity between the two.

## Naming the conflict

[`docs/deployment.md`](../../docs/deployment.md) states the product's shipped
position: "This repo carries only the **generic** pieces; a concrete
deployment (its domain, secrets, platform manifests) is yours to own — keep
those in your own infra repo." This stack is exactly that concrete,
platform-specific manifest set, requested directly rather than kept in a
separate infra repo.

What that costs: this stack will drift the way any infra-as-code drifts —
provider resource renames, a new pgvector-capable engine version, a changed
default in the underlying Terraform provider — and nothing here re-derives
that contract from the product the way `backend/gates/*` re-derive theirs from
the Go tree. There is no gate that fails when `MARGINCE_DSN` or the routing
table changes shape and this `.tf` tree does not follow. Treat it as a
**reference starting point** for an operator's own fork, not a promise of
ongoing parity — whether a team wants that parity enforced is
`status: needs-decision` territory; absent that decision this is "fix it,
don't file it" scoped to what shipped today.

## Shape

Serverless containers (ECS Fargate on AWS, Container Apps on Azure — no
cluster to operate on either) and a full managed stack (managed Postgres,
managed Redis, object storage, a secrets store, image registry, one
customer-managed key over all of it — all provisioned by Terraform). See
[`aws/README.md`](aws/README.md) or [`azure/README.md`](azure/README.md) for
each stack's full resource list, security posture, and how to use it.

## What this does NOT cover

Autoscaling policies beyond a fixed desired count, multi-region/HA, and
disaster recovery / backup-restore runbooks are out of scope — each is a real
decision (retention window, RPO/RTO, which regions) that belongs to the
operator standing this up, not a default this reference should pick for them.
(The AWS stack's own baseline WAF rules — see [`aws/README.md`](aws/README.md)
— are a floor every deployment gets, not a substitute for tuning rules to an
operator's own traffic.)

## Using the stack

```bash
cd deploy/terraform/aws   # or deploy/terraform/azure
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars
terraform init
terraform plan
terraform apply
```

**Local state is the default, and it is not the recommended posture beyond a
one-off `terraform plan`.** Every stack's `versions.tf` carries a commented
remote-backend block (`backend "s3"` for AWS, `backend "azurerm"` for Azure)
— uncomment and fill it in with your own state store before an `apply` you
intend to keep, or `terraform apply` writes the managed database, cache, and
every generated credential from that stack's own `secrets.tf` into a
plaintext file on whatever machine ran it.

Then follow that stack's own README ([`aws/README.md`](aws/README.md),
[`azure/README.md`](azure/README.md)) for the one-time steps Terraform does
not do: bootstrapping the database roles
(`scripts/deploy/db-bootstrap.sql`), mounting/writing `margince.yaml`, and
building/pushing the three images to the registry Terraform created.
