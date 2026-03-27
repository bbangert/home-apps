job "grafana" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "epyc"
  }

  group "grafana" {
    network {
      mode = "host"
      port "http" { static = 3001 }
    }

    volume "data" {
      type      = "host"
      source    = "grafana-data"
      read_only = false
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "grafana" {
      driver = "docker"

      config {
        image        = "grafana/grafana:11.6.0"
        network_mode = "host"
        ports        = ["http"]
      }

      volume_mount {
        volume      = "data"
        destination = "/var/lib/grafana"
      }

      env {
        GF_SERVER_HTTP_PORT       = "3001"
        GF_SERVER_ROOT_URL        = "https://grafana.groovie.org"
        GF_AUTH_ANONYMOUS_ENABLED = "false"
      }

      resources {
        cpu    = 500
        memory = 512
      }
    }
  }
}
