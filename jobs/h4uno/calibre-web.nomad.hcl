job "calibre-web" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "h4uno"
  }

  group "calibre-web" {
    network {
      mode = "host"
      port "http" { static = 8083 }
    }

    volume "config" {
      type      = "host"
      source    = "calibre-web-config"
      read_only = false
    }

    volume "books" {
      type      = "host"
      source    = "data-books"
      read_only = true
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "calibre-web" {
      driver = "docker"

      config {
        image        = "ghcr.io/bjw-s-labs/calibre-web:0.6.26"
        network_mode = "host"
        ports        = ["http"]
      }

      volume_mount {
        volume      = "config"
        destination = "/config"
      }

      volume_mount {
        volume      = "books"
        destination = "/books"
        read_only   = true
      }

      env {
        CACHE_DIR = "/tmp/cache"
        TZ        = "America/Los_Angeles"
      }

      resources {
        cpu        = 500
        memory     = 256
        memory_max = 512
      }
    }
  }
}
