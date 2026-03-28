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

    volume "dashboards" {
      type      = "host"
      source    = "grafana-dashboards"
      read_only = true
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
        image        = "grafana/grafana:11.6.14"
        network_mode = "host"
        ports        = ["http"]
      }

      volume_mount {
        volume      = "data"
        destination = "/var/lib/grafana"
      }

      volume_mount {
        volume      = "dashboards"
        destination = "/var/lib/grafana/dashboards"
      }

      # Provision VictoriaMetrics datasource
      template {
        data        = <<EOF
apiVersion: 1
datasources:
  - name: VictoriaMetrics
    type: prometheus
    uid: victoriametrics
    access: proxy
    url: http://127.0.0.1:8428
    isDefault: true
    editable: false
EOF
        destination = "local/provisioning/datasources/victoriametrics.yml"
      }

      # Provision dashboard provider
      template {
        data        = <<EOF
apiVersion: 1
providers:
  - name: homestar
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    allowUiUpdates: false
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: false
EOF
        destination = "local/provisioning/dashboards/homestar.yml"
      }

      env {
        GF_SERVER_HTTP_PORT       = "3001"
        GF_SERVER_ROOT_URL        = "https://grafana.groovie.org"
        GF_AUTH_ANONYMOUS_ENABLED = "false"
        GF_PATHS_PROVISIONING     = "/local/provisioning"
      }

      resources {
        cpu    = 500
        memory = 512
      }
    }
  }
}
