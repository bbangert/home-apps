job "ocis" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "epyc"
  }

  group "ocis" {
    network {
      mode = "host"
      port "http" { static = 9200 }
    }

    volume "data" {
      type      = "host"
      source    = "ocis-data"
      read_only = false
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "ocis" {
      driver = "docker"

      config {
        image        = "owncloud/ocis:8.0.1"
        network_mode = "host"
        ports        = ["http"]
      }

      volume_mount {
        volume      = "data"
        destination = "/ocis"
      }

      template {
        data        = <<EOF
{{ with nomadVar "nomad/jobs/ocis" -}}
OCIS_JWT_SECRET={{ .OCIS_JWT_SECRET }}
{{- end }}
EOF
        destination = "secrets/ocis.env"
        env         = true
      }

      env {
        OCIS_URL            = "https://files.groovie.org"
        OCIS_LOG_LEVEL      = "info"
        OCIS_LOG_COLOR      = "true"
        OCIS_LOG_PRETTY     = "true"
        OCIS_CONFIG_DIR     = "/ocis/config"
        OCIS_BASE_DATA_PATH = "/ocis/data"
        PROXY_TLS           = "false"
        DEMO_USERS          = "false"
        TZ                  = "America/Los_Angeles"
      }

      resources {
        cpu        = 1000
        memory     = 512
        memory_max = 1024
      }
    }
  }
}
