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
        image        = "grafana/grafana:13.0.1"
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

      # Provision Pushover contact point
      template {
        data        = <<EOF
{{ with nomadVar "nomad/jobs/grafana" -}}
apiVersion: 1
contactPoints:
  - orgId: 1
    name: Pushover
    receivers:
      - uid: pushover
        type: pushover
        settings:
          userKey: {{ .PUSHOVER_USER_KEY }}
          apiToken: {{ .PUSHOVER_APP_KEY }}
        disableResolveMessage: false
policies:
  - orgId: 1
    receiver: Pushover
    group_by:
      - grafana_folder
      - alertname
    group_wait: 30s
    group_interval: 5m
    repeat_interval: 4h
{{- end }}
EOF
        destination = "local/provisioning/alerting/contactpoints.yml"
      }

      # Provision alert rules
      template {
        data        = <<EOF
apiVersion: 1
deleteRules:
  - orgId: 1
    uid: node-down
groups:
  - orgId: 1
    name: Node Alerts
    folder: Alerts
    interval: 1m
    rules:
      - uid: disk-usage-high
        title: Disk usage > 85%
        condition: C
        data:
          - refId: A
            relativeTimeRange:
              from: 300
              to: 0
            datasourceUid: victoriametrics
            model:
              expr: disk_used_percent
              instant: true
          - refId: C
            relativeTimeRange:
              from: 0
              to: 0
            datasourceUid: __expr__
            model:
              type: threshold
              expression: A
              conditions:
                - evaluator:
                    type: gt
                    params: [85]
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: >-
            Disk usage is above 85% on {{ "{{" }} $labels.host {{ "}}" }} mount {{ "{{" }} $labels.path {{ "}}" }}

      - uid: memory-usage-high
        title: Memory usage > 90%
        condition: C
        data:
          - refId: A
            relativeTimeRange:
              from: 300
              to: 0
            datasourceUid: victoriametrics
            model:
              expr: mem_used_percent
              instant: true
          - refId: C
            relativeTimeRange:
              from: 0
              to: 0
            datasourceUid: __expr__
            model:
              type: threshold
              expression: A
              conditions:
                - evaluator:
                    type: gt
                    params: [90]
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: >-
            Memory usage is above 90% on {{ "{{" }} $labels.host {{ "}}" }}

      - uid: node-down-epyc
        title: Node down - epyc
        condition: C
        noDataState: Alerting
        data:
          - refId: A
            relativeTimeRange:
              from: 600
              to: 0
            datasourceUid: victoriametrics
            model:
              expr: system_uptime{host="epyc"}
              instant: true
          - refId: C
            relativeTimeRange:
              from: 0
              to: 0
            datasourceUid: __expr__
            model:
              type: threshold
              expression: A
              conditions:
                - evaluator:
                    type: lt
                    params: [0]
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: Node epyc is not reporting metrics

      - uid: node-down-h4uno
        title: Node down - h4uno
        condition: C
        noDataState: Alerting
        data:
          - refId: A
            relativeTimeRange:
              from: 600
              to: 0
            datasourceUid: victoriametrics
            model:
              expr: system_uptime{host="h4uno"}
              instant: true
          - refId: C
            relativeTimeRange:
              from: 0
              to: 0
            datasourceUid: __expr__
            model:
              type: threshold
              expression: A
              conditions:
                - evaluator:
                    type: lt
                    params: [0]
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: Node h4uno is not reporting metrics

      - uid: node-down-h4dos
        title: Node down - h4dos
        condition: C
        noDataState: Alerting
        data:
          - refId: A
            relativeTimeRange:
              from: 600
              to: 0
            datasourceUid: victoriametrics
            model:
              expr: system_uptime{host="h4dos"}
              instant: true
          - refId: C
            relativeTimeRange:
              from: 0
              to: 0
            datasourceUid: __expr__
            model:
              type: threshold
              expression: A
              conditions:
                - evaluator:
                    type: lt
                    params: [0]
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: Node h4dos is not reporting metrics

      - uid: node-down-beelink1
        title: Node down - beelink1
        condition: C
        noDataState: Alerting
        data:
          - refId: A
            relativeTimeRange:
              from: 600
              to: 0
            datasourceUid: victoriametrics
            model:
              expr: system_uptime{host="beelink1"}
              instant: true
          - refId: C
            relativeTimeRange:
              from: 0
              to: 0
            datasourceUid: __expr__
            model:
              type: threshold
              expression: A
              conditions:
                - evaluator:
                    type: lt
                    params: [0]
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: Node beelink1 is not reporting metrics

      - uid: high-load
        title: High load average
        condition: C
        data:
          - refId: A
            relativeTimeRange:
              from: 600
              to: 0
            datasourceUid: victoriametrics
            model:
              expr: system_load5
              instant: true
          - refId: C
            relativeTimeRange:
              from: 0
              to: 0
            datasourceUid: __expr__
            model:
              type: threshold
              expression: A
              conditions:
                - evaluator:
                    type: gt
                    params: [8]
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: >-
            5-minute load average is above 8 on {{ "{{" }} $labels.host {{ "}}" }}

      - uid: systemd-service-failed
        title: Systemd service failed
        condition: C
        data:
          - refId: A
            relativeTimeRange:
              from: 300
              to: 0
            datasourceUid: victoriametrics
            model:
              expr: systemd_units_active_code{name=~"telegraf.service|nomad.service|docker.service"} != 1
              instant: true
          - refId: C
            relativeTimeRange:
              from: 0
              to: 0
            datasourceUid: __expr__
            model:
              type: threshold
              expression: A
              conditions:
                - evaluator:
                    type: gt
                    params: [0]
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: >-
            Service {{ "{{" }} $labels.name {{ "}}" }} is not active on {{ "{{" }} $labels.host {{ "}}" }}

      - uid: nfs-mount-unavailable
        title: NFS mount unavailable
        condition: C
        noDataState: Alerting
        data:
          - refId: A
            relativeTimeRange:
              from: 600
              to: 0
            datasourceUid: victoriametrics
            model:
              expr: disk_used_percent{host="h4dos", path="/mnt/media"}
              instant: true
          - refId: C
            relativeTimeRange:
              from: 0
              to: 0
            datasourceUid: __expr__
            model:
              type: threshold
              expression: A
              conditions:
                - evaluator:
                    type: lt
                    params: [0]
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: NFS mount /mnt/media is unavailable on h4dos

      - uid: restic-backup-stale
        title: Restic backup older than 48h
        condition: C
        noDataState: Alerting
        data:
          - refId: A
            relativeTimeRange:
              from: 300
              to: 0
            datasourceUid: victoriametrics
            model:
              expr: restic_backup_age_seconds
              instant: true
          - refId: C
            relativeTimeRange:
              from: 0
              to: 0
            datasourceUid: __expr__
            model:
              type: threshold
              expression: A
              conditions:
                - evaluator:
                    type: gt
                    params: [172800]
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: >-
            Restic backup on {{ "{{" }} $labels.host {{ "}}" }} is older than 48 hours

      - uid: container-high-memory
        title: Container memory > 90%
        condition: C
        data:
          - refId: A
            relativeTimeRange:
              from: 300
              to: 0
            datasourceUid: victoriametrics
            model:
              expr: docker_container_mem_usage_percent
              instant: true
          - refId: C
            relativeTimeRange:
              from: 0
              to: 0
            datasourceUid: __expr__
            model:
              type: threshold
              expression: A
              conditions:
                - evaluator:
                    type: gt
                    params: [90]
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: >-
            Container {{ "{{" }} $labels.container_name {{ "}}" }} on {{ "{{" }} $labels.host {{ "}}" }} is using over 90% of its memory limit
EOF
        destination = "local/provisioning/alerting/rules.yml"
      }

      env {
        GF_SERVER_HTTP_PORT       = "3001"
        GF_SERVER_ROOT_URL        = "https://grafana.groovie.org"
        GF_AUTH_ANONYMOUS_ENABLED = "false"
        GF_PATHS_PROVISIONING     = "/local/provisioning"
      }

      resources {
        cpu        = 500
        memory     = 256
        memory_max = 512
      }
    }
  }
}
