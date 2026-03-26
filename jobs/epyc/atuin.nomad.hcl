job "atuin" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "epyc"
  }

  group "atuin" {
    network {
      mode = "host"
      port "http" { static = 8888 }
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "atuin" {
      driver = "docker"

      config {
        image        = "ghcr.io/atuinsh/atuin:v18.12.0"
        network_mode = "host"
        ports        = ["http"]
        args         = ["start"]
      }

      template {
        data        = <<EOF
{{ with nomadVar "nomad/jobs/atuin" -}}
ATUIN_DB_URI=postgres://{{ .POSTGRES_USER }}:{{ .POSTGRES_PASS }}@127.0.0.1:5432/atuin
{{- end }}
EOF
        destination = "secrets/atuin.env"
        env         = true
      }

      env {
        ATUIN_HOST             = "0.0.0.0"
        ATUIN_PORT             = "8888"
        ATUIN_OPEN_REGISTRATION = "true"
        ATUIN_TLS__ENABLE      = "false"
      }

      resources {
        cpu    = 500
        memory = 256
      }
    }
  }
}
