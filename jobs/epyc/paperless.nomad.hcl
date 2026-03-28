job "paperless" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "epyc"
  }

  group "paperless" {
    network {
      mode = "host"
      port "http" { static = 8010 }
    }

    volume "data" {
      type      = "host"
      source    = "paperless-data"
      read_only = false
    }

    volume "media" {
      type      = "host"
      source    = "paperless-media"
      read_only = false
    }

    volume "consume" {
      type      = "host"
      source    = "paperless-consume"
      read_only = false
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "paperless" {
      driver = "docker"

      config {
        image        = "ghcr.io/paperless-ngx/paperless-ngx:2.16.3"
        network_mode = "host"
        ports        = ["http"]
      }

      volume_mount {
        volume      = "data"
        destination = "/usr/src/paperless/data"
      }

      volume_mount {
        volume      = "media"
        destination = "/usr/src/paperless/media"
      }

      volume_mount {
        volume      = "consume"
        destination = "/usr/src/paperless/consume"
      }

      template {
        data        = <<EOF
{{ with nomadVar "nomad/jobs/paperless" -}}
PAPERLESS_SECRET_KEY={{ .SECRET_KEY }}
PAPERLESS_DBPASS={{ .POSTGRES_PASSWORD }}
{{- end }}
EOF
        destination = "secrets/paperless.env"
        env         = true
      }

      env {
        PAPERLESS_PORT = "8010"
        PAPERLESS_URL  = "https://paperless.groovie.org"
        PAPERLESS_TIME_ZONE = "America/Los_Angeles"

        # Database
        PAPERLESS_DBENGINE = "postgresql"
        PAPERLESS_DBHOST   = "127.0.0.1"
        PAPERLESS_DBPORT   = "5432"
        PAPERLESS_DBNAME   = "paperless"
        PAPERLESS_DBUSER   = "paperless"

        # Redis (Valkey)
        PAPERLESS_REDIS = "redis://127.0.0.1:6379/3"

        # OIDC via Authentik
        PAPERLESS_APPS = "allauth.socialaccount.providers.openid_connect"

        # OCR
        PAPERLESS_OCR_LANGUAGE = "eng"

        USERMAP_UID = "1000"
        USERMAP_GID = "1000"
      }

      resources {
        cpu    = 2000
        memory = 2048
      }
    }
  }
}
