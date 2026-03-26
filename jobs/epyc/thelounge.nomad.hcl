job "thelounge" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "epyc"
  }

  group "thelounge" {
    network {
      mode = "host"
      port "http" { static = 9090 }
    }

    volume "config" {
      type      = "host"
      source    = "thelounge-config"
      read_only = false
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "thelounge" {
      driver = "docker"

      config {
        image        = "ghcr.io/thelounge/thelounge:4.4.3"
        network_mode = "host"
        ports        = ["http"]
      }

      volume_mount {
        volume      = "config"
        destination = "/var/opt/thelounge"
      }

      env {
        THELOUNGE_HOME = "/var/opt/thelounge"
        PORT           = "9090"
      }

      resources {
        cpu    = 500
        memory = 512
      }
    }
  }
}
