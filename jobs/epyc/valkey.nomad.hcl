job "valkey" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "epyc"
  }

  group "cache" {
    network {
      mode = "host"
      port "redis" {
        static = 6379
      }
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "valkey" {
      driver = "docker"

      config {
        image        = "valkey/valkey:9-alpine"
        network_mode = "host"
        ports        = ["redis"]
        args         = ["valkey-server", "--bind", "127.0.0.1", "--port", "6379"]
      }

      resources {
        cpu        = 500
        memory     = 256
        memory_max = 512
      }
    }
  }
}
