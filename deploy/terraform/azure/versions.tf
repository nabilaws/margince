terraform {
  required_version = ">= 1.7.0"

  # No backend block: state defaults to local, which puts the Postgres/Redis/
  # Key Vault/webhook credentials every resource in secrets.tf generates into a
  # plaintext file on whatever machine runs `terraform apply` — fine for a
  # one-off `terraform plan` against this reference stack, not fine for an
  # actual deployment. Uncomment and fill in for anything beyond that:
  #
  # backend "azurerm" {
  #   resource_group_name  = "your-terraform-state-rg"
  #   storage_account_name = "yourterraformstate"
  #   container_name       = "margince-azure"
  #   key                  = "terraform.tfstate"
  #   use_azuread_auth     = true # authenticate with your own Azure AD identity
  #                                # rather than a long-lived storage account key
  # }
  #
  # No resource group/storage account name is filled in above on purpose — an
  # operator's state backend is theirs to own and scope access to, the same
  # reasoning docs/deployment.md gives for keeping concrete deployment
  # specifics out of this repo (see the AWS stack's identical versions.tf
  # comment for the backend "s3" case).

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.117"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    # entra.tf: the sign-in app registration, its enterprise-app assignment to
    # the customer's existing security group, and its client secret.
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.53"
    }
    # entra.tf's client-secret rotation clock.
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

provider "azurerm" {
  features {
    key_vault {
      # This stack's own Key Vault (keyvault.tf) carries purge_protection_enabled
      # = true — a deliberate, permanent choice mirroring kms.tf's 30-day KMS
      # deletion window, so Terraform must not fight that by trying to purge on
      # destroy (the API refuses it anyway once purge protection is on; this
      # keeps `terraform destroy` from erroring on every key/vault it touches).
      purge_soft_deleted_keys_on_destroy = false
      purge_soft_delete_on_destroy       = false
    }
  }
}

# Every resource that supports tags carries these two via provider default_tags
# equivalent — azurerm has no provider-level default_tags block the way the aws
# provider does, so this stack applies the same Project/ManagedBy pair as a
# local map (see network.tf's locals.common_tags) merged onto each resource's
# own tags instead. Environment/Component follow the same per-resource pattern
# AWS uses.

# Authenticates as whoever runs `terraform apply` (az login), in the tenant of
# the subscription above. entra.tf needs that identity to hold Entra's
# Application Administrator (or Cloud Application Administrator) role when
# create_entra_app = true; with create_entra_app = false it only reads the
# current tenant ID.
provider "azuread" {}
