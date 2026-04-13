job "paperless-ai" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "epyc"
  }

  group "paperless-ai" {
    network {
      mode = "host"
      port "http" { static = 3002 }
    }

    volume "data" {
      type      = "host"
      source    = "paperless-ai-data"
      read_only = false
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "paperless-ai" {
      driver = "docker"

      config {
        image        = "clusterzx/paperless-ai:latest"
        network_mode = "host"
        ports        = ["http"]
      }

      volume_mount {
        volume      = "data"
        destination = "/app/data"
      }

      env {
        PAPERLESS_AI_PORT = "3002"
        PUID              = "1000"
        PGID              = "1000"
      }

      resources {
        cpu        = 500
        memory     = 512
        memory_max = 1024
      }
    }
  }
}
