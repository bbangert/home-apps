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
        image   = "gcr.io/sigma-seer-289715/duketogo:d04aba49fe1ea41825a03933aeeb233bc3af56fd"
        command = "node"
        args    = ["./dist/main.js"]
      }

      volume_mount {
        volume      = "data"
        destination = "/data"
      }

      template {
        data        = <<EOF
{{ with nomadVar "nomad/jobs/duketogo" -}}
discord__token={{ .discord__token }}
sentry__dsn={{ .sentry__dsn }}
stonks__apiKey={{ .stonks__apiKey }}
{{- end }}
EOF
        destination = "secrets/duketogo.env"
        env         = true
      }

      env {
        DEBUG                   = "bot*"
        megahal__brainFile      = "/data/megahal.brn"
        megahal__maxInputTokens = "1000"
        megahal__maxOutputTokens = "1000"
      }

      resources {
        cpu    = 500
        memory = 512
      }
    }
  }
}
