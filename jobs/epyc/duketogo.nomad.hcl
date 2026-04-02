job "duketogo" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "epyc"
  }

  group "duketogo" {
    network {
      mode = "host"
    }

    volume "data" {
      type      = "host"
      source    = "duketogo-config"
      read_only = false
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "duketogo" {
      driver = "docker"

      config {
        image   = "ghcr.io/bbangert/duketogo_ex:latest"
      }

      volume_mount {
        volume      = "data"
        destination = "/data"
      }

      template {
        data        = <<EOF
{{ with nomadVar "nomad/jobs/duketogo" -}}
DISCORD_TOKEN={{ .DISCORD_TOKEN }}
ALPHA_VANTAGE_API_KEY={{ .ALPHA_VANTAGE_API_KEY }}
{{- end }}
EOF
        destination = "secrets/duketogo.env"
        env         = true
      }

      env {
        MEGAHAL_BRAIN_FILE = "/data/megahal.brn"
      }

      resources {
        cpu        = 500
        memory     = 256
        memory_max = 2048
      }
    }
  }
}
