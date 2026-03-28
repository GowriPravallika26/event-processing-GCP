resource "google_compute_network" "vpc" {
  name                    = "event-processing-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = "private-subnet-services"
  ip_cidr_range = "10.10.10.0/24"
  region        = var.region
  network       = google_compute_network.vpc.id
}

resource "google_vpc_access_connector" "connector" {
  name          = "serverless-connector"
  region        = var.region
  network       = google_compute_network.vpc.name
  ip_cidr_range = "10.8.0.0/28"
}

resource "google_compute_firewall" "allow_postgres" {
  name    = "allow-internal-postgres"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["5432"]
  }

  source_ranges = ["10.8.0.0/28"]
}

resource "google_sql_database_instance" "db_instance" {
  name             = "event-db-instance"
  database_version = "POSTGRES_13"
  region           = var.region

  settings {
    tier = "db-f1-micro"

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.vpc.id
    }
  }

  deletion_protection = false
}

resource "google_sql_database" "db" {
  name     = "events_db"
  instance = google_sql_database_instance.db_instance.name
}

resource "google_sql_user" "user" {
  name     = "event_user"
  instance = google_sql_database_instance.db_instance.name
  password = "TempPassword123"
}

resource "google_secret_manager_secret" "db_password" {
  secret_id = "db-password"

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "db_password_version" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = "TempPassword123"
}

resource "google_service_account" "function_sa" {
  account_id = "event-function-sa"
}

resource "google_project_iam_member" "pubsub_role" {
  project = var.project_id
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:${google_service_account.function_sa.email}"
}

resource "google_project_iam_member" "cloudsql_role" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.function_sa.email}"
}

resource "google_project_iam_member" "secret_role" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.function_sa.email}"
}

resource "google_pubsub_topic" "topic" {
  name = "gcs-events"
}

resource "google_storage_bucket" "bucket" {
  name     = "${var.project_id}-bucket-12345"
  location = var.region
}

resource "google_storage_notification" "notification" {
  bucket         = google_storage_bucket.bucket.name
  topic          = google_pubsub_topic.topic.id
  event_types    = ["OBJECT_FINALIZE"]
  payload_format = "JSON_API_V1"
}

resource "google_storage_bucket_object" "function_zip" {
  name   = "function.zip"
  bucket = google_storage_bucket.bucket.name
  source = "function.zip"
}

resource "google_cloudfunctions_function" "function" {
  name        = "event-function"
  runtime     = "python39"
  entry_point = "process_event"

  source_archive_bucket = google_storage_bucket.bucket.name
  source_archive_object = google_storage_bucket_object.function_zip.name

  event_trigger {
    event_type = "google.pubsub.topic.publish"
    resource   = google_pubsub_topic.topic.name
  }

  service_account_email = google_service_account.function_sa.email

  vpc_connector = google_vpc_access_connector.connector.name
}