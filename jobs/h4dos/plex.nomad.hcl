job "plex" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "h4dos"
  }

  group "plex" {
    network {
      mode = "host"
      port "http" { static = 32400 }
    }

    volume "config" {
      type      = "host"
      source    = "plex-config"
      read_only = false
    }

    volume "video" {
      type      = "host"
      source    = "data-video"
      read_only = true
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "plex" {
      driver = "docker"

      config {
        image        = "lscr.io/linuxserver/plex:1.43.0"
        network_mode = "host"
        ports        = ["http"]
        devices      = [{
          host_path      = "/dev/dri"
          container_path = "/dev/dri"
        }]
        group_add    = ["993"]
      }

      volume_mount {
        volume      = "config"
        destination = "/config/Library/Application Support/Plex Media Server"
      }

      volume_mount {
        volume      = "video"
        destination = "/data/media/Video"
        read_only   = true
      }

      env {
        PUID               = "568"
        PGID               = "568"
        TZ                 = "America/Los_Angeles"
        PLEX_ADVERTISE_URL = "https://192.168.2.39:32400,https://plex.groovie.org:443"
        PLEX_NO_AUTH_NETWORKS = "192.168.0.0/16"
      }

      resources {
        cpu        = 2000
        memory     = 4096
        memory_max = 8192
      }
    }
  }
}
