job "komf" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "h4uno"
  }

  group "komf" {
    network {
      mode = "host"
      port "http" { static = 8085 }
    }

    volume "config" {
      type      = "host"
      source    = "komf-config"
      read_only = false
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "komf" {
      driver = "docker"

      config {
        image        = "sndxr/komf:1.7.1"
        network_mode = "host"
        ports        = ["http"]
      }

      volume_mount {
        volume      = "config"
        destination = "/config"
      }

      template {
        data        = <<EOF
{{ with nomadVar "nomad/jobs/komf" -}}
KOMF_KOMGA_BASE_URI=http://localhost:25600
KOMF_KOMGA_USER={{ .KOMF_KOMGA_USER }}
KOMF_KOMGA_PASSWORD={{ .KOMF_KOMGA_PASSWORD }}
{{- end }}
KOMF_LOG_LEVEL=INFO
EOF
        destination = "secrets/komf.env"
        env         = true
      }

      resources {
        cpu        = 500
        memory     = 256
        memory_max = 512
      }
    }
  }
}
