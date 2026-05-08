job "sabnzbd" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "h4dos"
  }

  group "sabnzbd" {
    network {
      mode = "host"
      port "http" { static = 8080 }
    }

    volume "config" {
      type      = "host"
      source    = "sabnzbd-config"
      read_only = false
    }

    volume "downloads" {
      type      = "host"
      source    = "data-downloads"
      read_only = false
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "sabnzbd" {
      driver = "docker"

      config {
        image        = "lscr.io/linuxserver/sabnzbd:5.0.1"
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

      template {
        data        = <<EOF
{{ with nomadVar "nomad/jobs/sabnzbd" -}}
SABNZBD__API_KEY={{ .SABNZBD__API_KEY }}
SABNZBD__NZB_KEY={{ .SABNZBD__NZB_KEY }}
{{- end }}
EOF
        destination = "secrets/sabnzbd.env"
        env         = true
      }

      env {
        PUID                           = "568"
        PGID                           = "568"
        TZ                             = "America/Los_Angeles"
        SABNZBD__PORT                  = "8080"
        SABNZBD__HOST_WHITELIST_ENTRIES = "sabnzbd,sabnzbd.groovie.org"
      }

      resources {
        cpu        = 500
        memory     = 1024
        memory_max = 2048
      }
    }
  }
}
