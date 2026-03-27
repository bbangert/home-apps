job "cloudflared" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "epyc"
  }

  group "tunnel" {
    network {
      mode = "host"
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "cloudflared" {
      driver = "docker"

      config {
        image        = "cloudflare/cloudflared:latest"
        network_mode = "host"
        args         = ["tunnel", "--config", "/local/config.yml", "run"]
      }

      template {
        data        = <<EOF
tunnel: e30c91ae-29eb-4b4b-9a9c-c41df2dc7b90
credentials-file: /secrets/credentials.json
ingress:
  - service: http://127.0.0.1:8780
EOF
        destination = "local/config.yml"
      }

      template {
        data        = <<EOF
{{ with nomadVar "nomad/jobs/cloudflared" -}}
{{ .TUNNEL_CREDENTIALS }}
{{- end }}
EOF
        destination = "secrets/credentials.json"
      }

      resources {
        cpu    = 256
        memory = 256
      }
    }
  }
}
