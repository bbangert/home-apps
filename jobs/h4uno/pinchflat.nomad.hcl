job "pinchflat" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "h4uno"
  }

  group "pinchflat" {
    network {
      mode = "host"
      port "http" { static = 8945 }
    }

    volume "config" {
      type      = "host"
      source    = "pinchflat-config"
      read_only = false
    }

    volume "downloads" {
      type      = "host"
      source    = "data-music-youtube"
      read_only = false
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "pinchflat" {
      driver = "docker"

      config {
        image        = "ghcr.io/kieraneglin/pinchflat:latest"
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

      env {
        TZ = "America/Los_Angeles"
      }

      resources {
        cpu        = 1000
        memory     = 1024
        memory_max = 2048
      }
    }

    # Mints YouTube PO tokens so yt-dlp can access web-client formats
    # (including the Premium 256k audio). Pinchflat's yt-dlp reaches it
    # on 127.0.0.1:4416 via the bgutil plugin in the config volume.
    task "bgutil-provider" {
      driver = "docker"

      config {
        image        = "brainicism/bgutil-ytdlp-pot-provider:1.3.1"
        network_mode = "host"
      }

      env {
        TZ = "America/Los_Angeles"
      }

      resources {
        cpu        = 200
        memory     = 256
        memory_max = 512
      }
    }
  }
}
