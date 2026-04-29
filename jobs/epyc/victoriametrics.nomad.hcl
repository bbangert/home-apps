job "victoriametrics" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "epyc"
  }

  group "victoriametrics" {
    network {
      mode = "host"
      port "http" { static = 8428 }
    }

    volume "data" {
      type      = "host"
      source    = "victoriametrics-data"
      read_only = false
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "victoriametrics" {
      driver = "docker"

      config {
        image        = "victoriametrics/victoria-metrics:v1.142.0"
        network_mode = "host"
        ports        = ["http"]
        args         = ["-storageDataPath=/victoria-metrics-data", "-retentionPeriod=12", "-httpListenAddr=:8428"]
      }

      volume_mount {
        volume      = "data"
        destination = "/victoria-metrics-data"
      }

      resources {
        cpu        = 500
        memory     = 512
        memory_max = 1024
      }
    }
  }
}
