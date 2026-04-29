job "vaultwarden" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "epyc"
  }

  group "vaultwarden" {
    network {
      mode = "host"
      port "http"      { static = 8081 }
      port "websocket" { static = 3012 }
    }

    volume "data" {
      type      = "host"
      source    = "vaultwarden-config"
      read_only = false
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "vaultwarden" {
      driver = "docker"

      config {
        image        = "vaultwarden/server:1.35.8"
        network_mode = "host"
        ports        = ["http", "websocket"]
      }

      volume_mount {
        volume      = "data"
        destination = "/data"
      }

      template {
        data        = <<EOF
{{ with nomadVar "nomad/jobs/vaultwarden" -}}
DATABASE_URL=postgresql://{{ .POSTGRES_USER }}:{{ .POSTGRES_PASS }}@127.0.0.1:5432/vaultwarden
ADMIN_TOKEN={{ .ADMIN_TOKEN }}
{{- end }}
EOF
        destination = "secrets/vaultwarden.env"
        env         = true
      }

      env {
        DATA_FOLDER        = "data"
        ICON_CACHE_FOLDER  = "data/icon_cache"
        ATTACHMENTS_FOLDER = "data/attachments"
        DOMAIN             = "https://vaultwarden.groovie.org"
        TZ                 = "America/Los_Angeles"
        SIGNUPS_ALLOWED    = "false"
        WEBSOCKET_ENABLED  = "true"
        WEBSOCKET_ADDRESS  = "0.0.0.0"
        WEBSOCKET_PORT     = "3012"
        ROCKET_PORT        = "8081"
        SMTP_HOST          = "smtp-relay.groovie.org"
        SMTP_FROM          = "vaultwarden@groovie.org"
        SMTP_FROM_NAME     = "vaultwarden"
        SMTP_PORT          = "25"
        SMTP_SECURITY      = "off"
      }

      resources {
        cpu        = 500
        memory     = 256
        memory_max = 512
      }
    }
  }
}
