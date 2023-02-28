// Copyright 2023 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

resource "google_container_cluster" "services-gke" {
  name     = var.services_gke_config.cluster_name
  location = var.services_gke_config.location

  network    = google_compute_network.vpc.name
  subnetwork = google_compute_subnetwork.subnet[var.services_gke_config.location].name

  # See issue: https://github.com/hashicorp/terraform-provider-google/issues/10782
  ip_allocation_policy {}

  # Enabling Autopilot for this cluster
  enable_autopilot = true

  # Private IP Config
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
  }

  depends_on = [google_compute_subnetwork.subnet, google_project_service.project]
}

data "google_container_cluster" "services-gke" {
  name     = var.services_gke_config.cluster_name
  location = var.services_gke_config.location

  depends_on = [google_container_cluster.services-gke]
}

resource "google_service_account" "app-service-account" {
  account_id   = var.app_service_account_config.name
  display_name = var.app_service_account_config.description
  project      = var.project
}

data "google_iam_policy" "workload-id-policy" {
  binding {
    role = "roles/iam.workloadIdentityUser"
    members = [
      "serviceAccount:${var.project}.svc.id.goog[default/${var.k8s_service_account_id}]",
      "serviceAccount:${var.project}.svc.id.goog[${var.allocation_endpoint.agones_namespace}/agones-allocator]",
      "serviceAccount:${var.project}.svc.id.goog[default/ping-discovery]"
    ]
  }

  depends_on = [google_project_service.project]
}

resource "google_service_account_iam_policy" "app-service-account-iam" {
  service_account_id = google_service_account.app-service-account.name
  policy_data        = data.google_iam_policy.workload-id-policy.policy_data

  depends_on = [google_project_service.project, google_container_cluster.services-gke]
}

#
# IAM for Ping Discovery Service
#

resource "google_project_iam_custom_role" "ping_discovery_role" {
  role_id     = "globalGame.pingDiscovery"
  title       = "Global Game: Ping Discovery Service"
  description = "Allows querying of forwarding rules to dynamically discover ping endpoints"
  permissions = [
    "compute.forwardingRules.list",
  ]
}

resource "google_service_account_iam_binding" "ping-discovery-workload-identity-binding" {
  service_account_id = google_service_account.ping_discovery_sa.name
  role               = "roles/iam.workloadIdentityUser"

  members = [
    "serviceAccount:${var.project}.svc.id.goog[default/ping-discovery]"
  ]

  depends_on = [google_container_cluster.services-gke]
}

resource "google_service_account" "ping_discovery_sa" {
  project      = var.project
  account_id   = "ping-sa"
  display_name = "Ping Discovery Service Account"
}

resource "google_project_iam_member" "ping_discovery_sa" {
  project = var.project
  role    = google_project_iam_custom_role.ping_discovery_role.id
  member  = "serviceAccount:${google_service_account.ping_discovery_sa.email}"
}

# Make Service Account file for deploy with Cloud Deploy
resource "local_file" "services-ping-service-account" {
  content = templatefile(
    "${path.module}/files/services/ping-service-account.yaml.tpl", {
      service_email = google_service_account.ping_discovery_sa.email
  })
  filename = "${path.module}/${var.services_directory}/ping-discovery/service-account.yaml"
}
