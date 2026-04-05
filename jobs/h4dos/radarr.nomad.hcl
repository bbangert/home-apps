job "radarr" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "h4dos"
  }

  group "radarr" {
    network {
      mode = "host"
      port "http" { static = 7878 }
    }

    volume "config" {
      type      = "host"
      source    = "radarr-config"
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

    task "radarr" {
      driver = "docker"

      config {
        image        = "lscr.io/linuxserver/radarr:6.1.1"
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
{{ with nomadVar "nomad/jobs/radarr" -}}
RADARR__AUTH__APIKEY={{ .RADARR__API_KEY }}
RADARR__POSTGRES__USER={{ .RADARR__POSTGRES_USER }}
RADARR__POSTGRES__PASSWORD={{ .RADARR__POSTGRES_PASSWORD }}
{{- end }}
EOF
        destination = "secrets/radarr.env"
        env         = true
      }

      env {
        PUID                       = "568"
        PGID                       = "568"
        TZ                         = "America/Los_Angeles"
        RADARR__POSTGRES__HOST     = "192.168.2.35"
        RADARR__POSTGRES__PORT     = "5432"
        RADARR__POSTGRES__MAINDB   = "radarr_main"
        RADARR__POSTGRES__LOGDB    = "radarr_log"
      }

      resources {
        cpu        = 1000
        memory     = 1024
        memory_max = 2048
      }
    }
  }
}
