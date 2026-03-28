job "prowlarr" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "h4dos"
  }

  group "prowlarr" {
    network {
      mode = "host"
      port "http" { static = 9696 }
    }

    volume "config" {
      type      = "host"
      source    = "prowlarr-config"
      read_only = false
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "prowlarr" {
      driver = "docker"

      config {
        image        = "lscr.io/linuxserver/prowlarr:2.3.0"
        network_mode = "host"
        ports        = ["http"]
      }

      volume_mount {
        volume      = "config"
        destination = "/config"
      }

      template {
        data        = <<EOF
{{ with nomadVar "nomad/jobs/prowlarr" -}}
PROWLARR__AUTH__APIKEY={{ .PROWLARR__API_KEY }}
PROWLARR__POSTGRES__USER={{ .PROWLARR__POSTGRES_USER }}
PROWLARR__POSTGRES__PASSWORD={{ .PROWLARR__POSTGRES_PASSWORD }}
{{- end }}
EOF
        destination = "secrets/prowlarr.env"
        env         = true
      }

      env {
        PUID                         = "568"
        PGID                         = "568"
        TZ                           = "America/Los_Angeles"
        PROWLARR__POSTGRES__HOST     = "192.168.2.35"
        PROWLARR__POSTGRES__PORT     = "5432"
        PROWLARR__POSTGRES__MAINDB   = "prowlarr_main"
      }

      resources {
        cpu    = 500
        memory = 512
      }
    }
  }
}
