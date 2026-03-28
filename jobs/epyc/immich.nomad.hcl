job "immich" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "epyc"
  }

  group "immich" {
    network {
      mode = "host"
      port "http" { static = 2283 }
      port "ml"   { static = 3003 }
      port "pg"   { static = 5433 }
    }

    volume "data" {
      type      = "host"
      source    = "immich-data"
      read_only = false
    }

    volume "ml-cache" {
      type      = "host"
      source    = "immich-ml-cache"
      read_only = false
    }

    volume "pg-data" {
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

      lifecycle {
        hook    = "prestart"
        sidecar = true
      }

      config {
        image        = "ghcr.io/immich-app/postgres:17-vectorchord0.5.3-pgvector0.8.1"
        network_mode = "host"
        ports        = ["pg"]
      }

      volume_mount {
        volume      = "pg-data"
        destination = "/var/lib/postgresql/data"
      }

      template {
        data        = <<EOF
{{ with nomadVar "nomad/jobs/immich" -}}
POSTGRES_PASSWORD={{ .DB_PASSWORD }}
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

    task "server" {
      driver = "docker"

      config {
        image        = "ghcr.io/immich-app/immich-server:v2.6.3"
        network_mode = "host"
        ports        = ["http"]
      }

      volume_mount {
        volume      = "data"
        destination = "/usr/src/app/upload"
      }

      template {
        data        = <<EOF
{{ with nomadVar "nomad/jobs/immich" -}}
DB_PASSWORD={{ .DB_PASSWORD }}
{{- end }}
EOF
        destination = "secrets/immich.env"
        env         = true
      }

      env {
        DB_HOSTNAME                 = "127.0.0.1"
        DB_PORT                     = "5433"
        DB_DATABASE_NAME            = "immich"
        DB_USERNAME                 = "immich"
        REDIS_HOSTNAME              = "127.0.0.1"
        REDIS_PORT                  = "6379"
        REDIS_DBINDEX               = "2"
        IMMICH_MACHINE_LEARNING_URL = "http://127.0.0.1:3003"
      }

      resources {
        cpu    = 4000
        memory = 4096
      }
    }

    task "machine-learning" {
      driver = "docker"

      config {
        image        = "ghcr.io/immich-app/immich-machine-learning:v2.6.3"
        network_mode = "host"
        ports        = ["ml"]
      }

      volume_mount {
        volume      = "data"
        destination = "/usr/src/app/upload"
      }

      volume_mount {
        volume      = "ml-cache"
        destination = "/cache"
      }

      resources {
        cpu    = 4000
        memory = 4096
      }
    }
  }
}
