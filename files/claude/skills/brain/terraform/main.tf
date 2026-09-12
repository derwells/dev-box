terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

# ----------------------------------------------------------------------------
# AUTH (bootstrap only — isolated from your WORK gcloud state)
#
# `terraform apply` needs credentials. For a personal account, authenticate ONCE
# in a separate config dir so work ADC is never written:
#
#   export CLOUDSDK_CONFIG="$HOME/.config/gcloud-personal"
#   gcloud auth application-default login        # consent as your personal account
#   export GOOGLE_APPLICATION_CREDENTIALS="$CLOUDSDK_CONFIG/application_default_credentials.json"
#   terraform init && terraform apply
#
# This is provisioning-only; `gws` at runtime does NOT use gcloud/ADC.
#
# ALTERNATIVE (no gcloud at all): just click "Enable" on the Gmail, Calendar, and
# Tasks APIs in the browser console for project brain-500508. Then you can skip this
# Terraform entirely.
# ----------------------------------------------------------------------------

provider "google" {
  project = var.project_id
}

variable "project_id" {
  description = "Existing GCP project id"
  type        = string
  default     = "brain-500508"
}

# The project already exists (created manually), so Terraform only enables the APIs.
# Note: the first apply may need the Service Usage + Cloud Resource Manager APIs
# already on; if you hit a 'has not been used / disabled' error, enable that one
# API once in the console, then re-apply.
resource "google_project_service" "apis" {
  for_each = toset([
    "gmail.googleapis.com",
    "calendar-json.googleapis.com", # Google Calendar API
    "tasks.googleapis.com",
  ])

  project = var.project_id
  service = each.value

  disable_on_destroy = false
}

output "enabled_apis" {
  value       = [for s in google_project_service.apis : s.service]
  description = "APIs enabled on the project."
}

output "next_steps" {
  value = <<-EOT
    APIs enabled on ${var.project_id}. Terraform CANNOT create the OAuth client
    (Google exposes no API for "Desktop app" clients). Finish manually in the console:
      1. APIs & Services > OAuth consent screen > External > add yourself > Publishing: In production
      2. APIs & Services > Credentials > Create credentials > OAuth client ID > Desktop app
      3. Download the JSON to ~/.config/gws/client_secret.json   (then: gws auth login)
  EOT
}
