job "openarchiver" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "epyc"
  }

  group "openarchiver" {
    network {
      mode = "host"
      port "http"   { static = 3400 }
      port "api"    { static = 4000 }
      port "redis"  { static = 6380 }
      port "search" { static = 7700 }
      port "tika"   { static = 9998 }
    }

    volume "data" {
      type      = "host"
      source    = "openarchiver-data"
      read_only = false
    }

    volume "meili" {
      type      = "host"
      source    = "openarchiver-meili"
      read_only = false
    }

    volume "valkey" {
      type      = "host"
      source    = "openarchiver-valkey"
      read_only = false
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    # Dedicated Valkey: BullMQ queues need noeviction, and the shared
    # instance on 6379 is an allkeys-lru cache.
    task "valkey" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        sidecar = true
      }

      config {
        image        = "valkey/valkey:8-alpine"
        network_mode = "host"
        ports        = ["redis"]
        args         = ["valkey-server", "/secrets/valkey.conf"]
      }

      volume_mount {
        volume      = "valkey"
        destination = "/data"
      }

      template {
        data        = <<EOF
bind 127.0.0.1
port 6380
dir /data
maxmemory-policy noeviction
{{ with nomadVar "nomad/jobs/openarchiver" -}}
requirepass {{ .REDIS_PASSWORD }}
{{- end }}
EOF
        destination = "secrets/valkey.conf"
      }

      resources {
        cpu        = 200
        memory     = 256
        memory_max = 512
      }
    }

    task "meilisearch" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        sidecar = true
      }

      config {
        image        = "getmeili/meilisearch:v1.55.0"
        network_mode = "host"
        ports        = ["search"]
      }

      volume_mount {
        volume      = "meili"
        destination = "/meili_data"
      }

      template {
        data        = <<EOF
{{ with nomadVar "nomad/jobs/openarchiver" -}}
MEILI_MASTER_KEY={{ .MEILI_MASTER_KEY }}
{{- end }}
EOF
        destination = "secrets/meilisearch.env"
        env         = true
      }

      env {
        MEILI_ENV               = "production"
        MEILI_HTTP_ADDR         = "127.0.0.1:7700"
        MEILI_NO_ANALYTICS      = "true"
        MEILI_SCHEDULE_SNAPSHOT = "86400"
      }

      resources {
        cpu        = 1000
        memory     = 1024
        memory_max = 4096
      }
    }

    # Attachment text extraction. Listens on all interfaces; 9998 is not
    # opened in ufw, so it is only reachable from epyc itself.
    task "tika" {
      driver = "docker"

      lifecycle {
        hook    = "prestart"
        sidecar = true
      }

      config {
        image        = "apache/tika:3.2.2.0-full"
        network_mode = "host"
        ports        = ["tika"]
      }

      resources {
        cpu        = 1000
        memory     = 1024
        memory_max = 2048
      }
    }

    task "openarchiver" {
      driver = "docker"

      config {
        image        = "logiclabshq/open-archiver:v0.6.0"
        network_mode = "host"
        ports        = ["http", "api"]
      }

      volume_mount {
        volume      = "data"
        destination = "/var/data/open-archiver"
      }

      template {
        data        = <<EOF
{{ with nomadVar "nomad/jobs/openarchiver" -}}
DATABASE_URL=postgresql://openarchiver:{{ .POSTGRES_PASSWORD }}@127.0.0.1:5432/openarchiver
REDIS_PASSWORD={{ .REDIS_PASSWORD }}
MEILI_MASTER_KEY={{ .MEILI_MASTER_KEY }}
JWT_SECRET={{ .JWT_SECRET }}
ENCRYPTION_KEY={{ .ENCRYPTION_KEY }}
{{- end }}
EOF
        destination = "secrets/openarchiver.env"
        env         = true
      }

      env {
        NODE_ENV = "production"
        # The frontend (SvelteKit node adapter) listens on PORT; upstream's
        # PORT_FRONTEND only sets the compose port mapping.
        PORT         = "3400"
        PORT_BACKEND = "4000"
        APP_URL      = "https://openarchiver.groovie.org"
        ORIGIN       = "https://openarchiver.groovie.org"
        TZ           = "America/Los_Angeles"

        # Ingestion
        SYNC_FREQUENCY        = "*/5 * * * *"
        ALL_INCLUSIVE_ARCHIVE = "false"
        ENABLE_DELETION       = "false"
        BODY_SIZE_LIMIT       = "Infinity"

        # Storage on the host volume
        STORAGE_TYPE            = "local"
        STORAGE_LOCAL_ROOT_PATH = "/var/data/open-archiver"

        # Sidecars
        REDIS_HOST        = "127.0.0.1"
        REDIS_PORT        = "6380"
        REDIS_TLS_ENABLED = "false"
        MEILI_HOST        = "http://127.0.0.1:7700"
        TIKA_URL          = "http://127.0.0.1:9998"

        JWT_EXPIRES_IN = "7d"
      }

      resources {
        cpu        = 2000
        memory     = 2048
        memory_max = 4096
      }
    }
  }
}
