job "sonarr" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "h4dos"
  }

  group "sonarr" {
    network {
      mode = "host"
      port "http" { static = 8989 }
    }

    volume "config" {
      type      = "host"
      source    = "sonarr-config"
      read_only = false
    }

    volume "downloads" {
      type      = "host"
      source    = "data-downloads"
      read_only = false
    }

    volume "video" {
      type      = "host"
      source    = "data-video"
      read_only = false
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "sonarr" {
      driver = "docker"

      config {
        image        = "lscr.io/linuxserver/sonarr:4.0.17"
        network_mode = "host"
        ports        = ["http"]
      }

      volume_mount {
        volume      = "config"
        destination = "/config"
      }

      volume_mount {
        volume      = "downloads"
        destination = "/downloads"
      }

      volume_mount {
        volume      = "video"
        destination = "/video"
      }

      template {
        data        = <<EOF
{{ with nomadVar "nomad/jobs/sonarr" -}}
SONARR__AUTH__APIKEY={{ .SONARR__API_KEY }}
SONARR__POSTGRES__USER={{ .SONARR__POSTGRES_USER }}
SONARR__POSTGRES__PASSWORD={{ .SONARR__POSTGRES_PASSWORD }}
{{- end }}
EOF
        destination = "secrets/sonarr.env"
        env         = true
      }

      env {
        PUID                       = "568"
        PGID                       = "568"
        TZ                         = "America/Los_Angeles"
        SONARR__POSTGRES__HOST     = "192.168.2.35"
        SONARR__POSTGRES__PORT     = "5432"
        SONARR__POSTGRES__MAINDB   = "sonarr_main"
        SONARR__POSTGRES__LOGDB    = "sonarr_log"
      }

      resources {
        cpu        = 1000
        memory     = 1024
        memory_max = 2048
      }
    }
  }
}
