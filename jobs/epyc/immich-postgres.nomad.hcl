job "immich-postgres" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "epyc"
  }

  group "db" {
    network {
      mode = "host"
      port "pg" {
        static = 5433
      }
    }

    volume "data" {
      type      = "host"
      source    = "immich-pg-data"
      read_only = false
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "postgres" {
      driver = "docker"

      config {
        image        = "ghcr.io/immich-app/postgres:17-vectorchord0.5.3-pgvector0.8.1"
        network_mode = "host"
        ports        = ["pg"]
      }

      volume_mount {
        volume      = "data"
        destination = "/var/lib/postgresql/data"
      }

      # Secrets are stored in Nomad Variables. Load once (or refresh) with:
      # nomad var put nomad/jobs/immich-postgres \
      #   POSTGRES_PASSWORD=$(op read op://HomeCluster/immich/POSTGRES_PASS)
      template {
        data        = <<EOF
{{ with nomadVar "nomad/jobs/immich-postgres" -}}
POSTGRES_PASSWORD={{ .POSTGRES_PASSWORD }}
{{- end }}
EOF
        destination = "secrets/db.env"
        env         = true
      }

      env {
        POSTGRES_DB   = "immich"
        POSTGRES_USER = "immich"
        PGPORT        = "5433"
      }

      resources {
        cpu    = 1000
        memory = 2048
      }
    }
  }
}
