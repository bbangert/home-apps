job "lidarr" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "h4dos"
  }

  group "lidarr" {
    network {
      mode = "host"
      port "http" { static = 8686 }
    }

    volume "config" {
      type      = "host"
      source    = "lidarr-config"
      read_only = false
    }

    volume "downloads" {
      type      = "host"
      source    = "data-downloads"
      read_only = false
    }

    volume "music" {
      type      = "host"
      source    = "data-music"
      read_only = false
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "lidarr" {
      driver = "docker"

      config {
        image        = "lscr.io/linuxserver/lidarr:8.1.2135"
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
        volume      = "music"
        destination = "/music"
      }

      template {
        data        = <<EOF
{{ with nomadVar "nomad/jobs/lidarr" -}}
LIDARR__API_KEY={{ .LIDARR__API_KEY }}
LIDARR__POSTGRES_USER={{ .LIDARR__POSTGRES_USER }}
LIDARR__POSTGRES_PASSWORD={{ .LIDARR__POSTGRES_PASSWORD }}
{{- end }}
EOF
        destination = "secrets/lidarr.env"
        env         = true
      }

      env {
        TZ                      = "America/Los_Angeles"
        PUID                    = "568"
        PGID                    = "568"
        LIDARR__INSTANCE_NAME   = "Lidarr"
        LIDARR__LOG_LEVEL       = "info"
        LIDARR__PORT            = "8686"
        LIDARR__POSTGRES_HOST   = "192.168.2.35"
        LIDARR__POSTGRES_PORT   = "5432"
        LIDARR__POSTGRES_MAINDB = "lidarr_main"
        LIDARR__POSTGRES_LOGDB  = "lidarr_log"
      }

      resources {
        cpu        = 1000
        memory     = 1024
        memory_max = 2048
      }
    }
  }
}
