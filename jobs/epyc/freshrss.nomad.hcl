job "freshrss" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "epyc"
  }

  group "freshrss" {
    network {
      mode = "host"
      port "http" { static = 8082 }
    }

    volume "config" {
      type      = "host"
      source    = "freshrss-config"
      read_only = false
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "freshrss" {
      driver = "docker"

      config {
        image        = "freshrss/freshrss:1.28.1"
        network_mode = "host"
        ports        = ["http"]
      }

      volume_mount {
        volume      = "config"
        destination = "/var/www/FreshRSS/data"
      }

      template {
        data        = <<EOF
{{ with nomadVar "nomad/jobs/freshrss" -}}
OIDC_CLIENT_ID={{ .OIDC_CLIENT_ID }}
OIDC_CLIENT_SECRET={{ .OIDC_CLIENT_SECRET }}
FRESHRSS_OIDC_CLIENT_CRYPTO_KEY={{ .FRESHRSS_OIDC_CLIENT_CRYPTO_KEY }}
POSTGRES_USER={{ .POSTGRES_USER }}
POSTGRES_PASSWORD={{ .POSTGRES_PASSWORD }}
{{- end }}
EOF
        destination = "secrets/freshrss.env"
        env         = true
      }

      env {
        TZ                       = "America/Los_Angeles"
        CRON_MIN                 = "18,48"
        LISTEN                   = "0.0.0.0:8082"
        FRESHRSS_ENV             = "production"
        DOMAIN                   = "https://freshrss.groovie.org/"
        OIDC_ENABLED             = "1"
        OIDC_PROVIDER_METADATA_URL = "https://auth.groovie.org/application/o/freshrss/.well-known/openid-configuration"
        OIDC_REMOTE_USER_CLAIM   = "preferred_username"
        OIDC_SCOPES              = "openid groups email profile"
        OIDC_X_FORWARDED_HEADERS = "X-Forwarded-Host X-Forwarded-Port X-Forwarded-Proto"
      }

      resources {
        cpu    = 500
        memory = 256
      }
    }
  }
}
