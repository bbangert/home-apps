job "smtp-relay" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "epyc"
  }

  group "smtp-relay" {
    network {
      mode = "host"
      port "smtp" { static = 25 }
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "maddy" {
      driver = "docker"

      config {
        image        = "ghcr.io/foxcpp/maddy:0.9.4"
        network_mode = "host"
        ports        = ["smtp"]
        volumes      = ["local/maddy.conf:/data/maddy.conf:ro"]
      }

      template {
        data        = <<EOF
{{ with nomadVar "nomad/jobs/smtp-relay" -}}
SMTP_RELAY_HOSTNAME={{ .SMTP_RELAY_HOSTNAME }}
SMTP_RELAY_SERVER={{ .SMTP_RELAY_SERVER }}
SMTP_RELAY_SERVER_PORT=465
SMTP_RELAY_USERNAME={{ .SMTP_RELAY_USERNAME }}
SMTP_RELAY_PASSWORD={{ .SMTP_RELAY_PASSWORD }}
{{- end }}
SMTP_RELAY_SMTP_PORT=25
EOF
        destination = "secrets/smtp-relay.env"
        env         = true
      }

      template {
        data        = <<EOF
state_dir /cache/state
runtime_dir /cache/run

tls off
hostname {env:SMTP_RELAY_HOSTNAME}

smtp tcp://0.0.0.0:{env:SMTP_RELAY_SMTP_PORT} {
    default_source {
        deliver_to &remote_queue
    }
}

target.queue remote_queue {
    target &remote_smtp
}

target.smtp remote_smtp {
    attempt_starttls yes
    require_tls yes
    auth plain {env:SMTP_RELAY_USERNAME} {env:SMTP_RELAY_PASSWORD}
    targets tls://{env:SMTP_RELAY_SERVER}:{env:SMTP_RELAY_SERVER_PORT}
}
EOF
        destination = "local/maddy.conf"
      }

      resources {
        cpu        = 100
        memory     = 64
        memory_max = 128
      }
    }
  }
}
