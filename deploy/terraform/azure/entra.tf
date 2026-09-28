# Entra ID: Margince reuses the customer's existing tenant, the same way their
# Dataverse environment does.
#
#   Who may sign in   one enterprise app with "assignment required", assigned
#                     the SAME security group that gates Dataverse, so Entra
#                     refuses to issue a token to anyone outside it.
#   MFA, device, etc. the customer's existing Conditional Access policy, with
#                     this app added to it (a manual step, README.md: this
#                     stack never edits a CA policy it does not own).
#   Staff sign-in     Margince's own Microsoft OIDC login
#                     (/v1/auth/oidc/microsoft/*), pinned to this tenant by
#                     MARGINCE_MICROSOFT_SIGNIN_TENANT.
#   Mailbox capture   the Graph connector, same app and secret
#                     (MARGINCE_GRAPH_CLIENT_ID/SECRET, cmd/api/config.go).
#
# Dataverse's own server-to-server access does not go through this app: it
# uses the managed identity in identity.tf (dataverse), registered in
# Dataverse as an application user.

data "azuread_client_config" "current" {}

data "azuread_application_published_app_ids" "well_known" {
  count = var.create_entra_app ? 1 : 0
}

data "azuread_service_principal" "msgraph" {
  count     = var.create_entra_app ? 1 : 0
  client_id = data.azuread_application_published_app_ids.well_known[0].result["MicrosoftGraph"]
}

locals {
  # Delegated Graph permissions, each with the code that asks for it:
  #   openid, email, profile           Microsoft sign-in (identity/ssologin.go)
  #   offline_access, User.Read,
  #   Mail.Read, Mail.Send             mail capture and send (compose/capture.go graphScopes)
  #   Calendars.Read                   calendar capture (capture/graphcal/client.go)
  graph_delegated_scopes = ["openid", "email", "profile", "offline_access", "User.Read", "Mail.Read", "Mail.Send", "Calendars.Read"]

  # Every OAuth callback the api serves under public_base_url.
  entra_redirect_uris = [
    "${var.public_base_url}/v1/auth/oidc/microsoft/callback",
    "${var.public_base_url}/v1/connectors/graph/callback",
    "${var.public_base_url}/v1/connectors/graphcal/callback",
  ]

  entra_client_id     = var.create_entra_app ? azuread_application.margince[0].client_id : var.entra_client_id
  entra_client_secret = var.create_entra_app ? azuread_application_password.margince[0].value : var.entra_client_secret
  entra_tenant_id     = data.azuread_client_config.current.tenant_id
}

# Fails the plan, not the first sign-in, when the inputs for the chosen mode
# are missing.
resource "terraform_data" "entra_inputs" {
  lifecycle {
    precondition {
      condition     = !var.create_entra_app || length(trimspace(var.entra_access_group_object_id)) > 0
      error_message = "create_entra_app = true needs entra_access_group_object_id: the security group that already gates the Dataverse environment."
    }
    precondition {
      condition     = var.create_entra_app || (length(trimspace(var.entra_client_id)) > 0 && length(var.entra_client_secret) > 0)
      error_message = "create_entra_app = false needs entra_client_id and entra_client_secret from the hand-made app registration."
    }
  }
}

resource "azuread_application" "margince" {
  count            = var.create_entra_app ? 1 : 0
  display_name     = "Margince (${var.name_prefix})"
  owners           = [data.azuread_client_config.current.object_id]
  sign_in_audience = "AzureADMyOrg" # this tenant only

  web {
    redirect_uris = local.entra_redirect_uris
    implicit_grant {
      access_token_issuance_enabled = false
      id_token_issuance_enabled     = false
    }
  }

  required_resource_access {
    resource_app_id = data.azuread_application_published_app_ids.well_known[0].result["MicrosoftGraph"]

    dynamic "resource_access" {
      for_each = local.graph_delegated_scopes
      content {
        id   = data.azuread_service_principal.msgraph[0].oauth2_permission_scope_ids[resource_access.value]
        type = "Scope"
      }
    }
  }

  depends_on = [terraform_data.entra_inputs]
}

resource "azuread_service_principal" "margince" {
  count     = var.create_entra_app ? 1 : 0
  client_id = azuread_application.margince[0].client_id
  owners    = [data.azuread_client_config.current.object_id]

  # "Assignment required": only principals assigned below (the security group)
  # can get a token for this app. Everyone else is refused by Entra itself,
  # before Margince sees a request.
  app_role_assignment_required = true

  feature_tags {
    enterprise = true
  }
}

resource "azuread_app_role_assignment" "access_group" {
  count               = var.create_entra_app ? 1 : 0
  app_role_id         = "00000000-0000-0000-0000-000000000000" # default access, no app roles defined
  principal_object_id = var.entra_access_group_object_id
  resource_object_id  = azuread_service_principal.margince[0].object_id
}

resource "time_rotating" "entra_secret" {
  count         = var.create_entra_app ? 1 : 0
  rotation_days = var.entra_secret_rotation_days
}

resource "azuread_application_password" "margince" {
  count          = var.create_entra_app ? 1 : 0
  application_id = azuread_application.margince[0].id
  display_name   = "terraform (${var.name_prefix})"
  # Valid a little longer than the rotation period, so the apply that rotates
  # it has room to happen late without an outage.
  end_date_relative = "${(var.entra_secret_rotation_days + 30) * 24}h"

  rotate_when_changed = {
    rotation = time_rotating.entra_secret[0].id
  }
}

resource "azuread_service_principal_delegated_permission_grant" "admin_consent" {
  count                                = var.create_entra_app && var.entra_grant_admin_consent ? 1 : 0
  service_principal_object_id          = azuread_service_principal.margince[0].object_id
  resource_service_principal_object_id = data.azuread_service_principal.msgraph[0].object_id
  claim_values                         = local.graph_delegated_scopes
}
