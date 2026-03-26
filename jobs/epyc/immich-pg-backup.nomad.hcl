job "immich-pg-backup" {
  datacenters = ["homestar"]
  type        = "batch"

  periodic {
    crons            = ["0 3 * * *"]
    prohibit_overlap = true
  }

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "epyc"
  }

  group "backup" {
    network {
      mode = "host"
    }

    restart {
      attempts = 1
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "pg-dump" {
      driver = "docker"

      config {
        image        = "postgres:17-alpine"
        network_mode = "host"
        volumes      = ["/mnt/backups/immich-pg:/backups"]
        command      = "/bin/sh"
        args         = ["/local/backup.sh"]
      }

      template {
        data        = <<SCRIPT
#!/bin/sh
set -e
STAMP=$(date +%Y%m%d_%H%M%S)
pg_dump -Fc -h 127.0.0.1 -p 5433 -U immich immich > /backups/immich_$STAMP.dump
# Keep last 7 daily backups
ls -t /backups/immich_*.dump | tail -n +8 | xargs -r rm
echo "Backup complete: immich_$STAMP.dump"
SCRIPT
        destination = "local/backup.sh"
      }

      template {
        data        = <<EOF
{{ with nomadVar "nomad/jobs/immich" -}}
PGPASSWORD={{ .DB_PASSWORD }}
{{- end }}
EOF
        destination = "secrets/pg.env"
        env         = true
      }

      resources {
        cpu    = 500
        memory = 512
      }
    }
  }
}
