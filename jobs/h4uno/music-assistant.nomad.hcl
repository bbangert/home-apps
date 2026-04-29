job "music-assistant" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "h4uno"
  }

  group "music-assistant" {
    network {
      mode = "host"
      port "http" { static = 8095 }
    }

    volume "data" {
      type      = "host"
      source    = "music-assistant-config"
      read_only = false
    }

    volume "music" {
      type      = "host"
      source    = "data-music"
      read_only = true
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "music-assistant" {
      driver = "docker"

      config {
        image        = "ghcr.io/music-assistant/server:2.8.6"
        network_mode = "host"
        ports        = ["http"]
      }

      volume_mount {
        volume      = "data"
        destination = "/data"
      }

      volume_mount {
        volume      = "music"
        destination = "/music"
        read_only   = true
      }

      env {
        TZ = "America/Los_Angeles"
      }

      resources {
        cpu        = 1000
        memory     = 4096
        memory_max = 8192
      }
    }
  }
}
