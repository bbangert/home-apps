job "paste" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "epyc"
  }

  group "paste" {
    network {
      mode = "host"
      port "http" { static = 6543 }
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "paste" {
      driver = "docker"

      config {
        image        = "bbangert/ofcode:0.4"
        network_mode = "host"
        ports        = ["http"]
      }

      resources {
        cpu        = 500
        memory     = 256
        memory_max = 512
      }
    }
  }
}
