job "authentik" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "epyc"
  }

  group "authentik" {
    network {
      mode = "host"
      port "http" {
        static = 9000
      }
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "server" {
      driver = "docker"

      config {
        image        = "ghcr.io/goauthentik/server:2026.2.2"
        network_mode = "host"
        ports        = ["http"]
        args         = ["server"]
        volumes      = [
          "/srv/authentik/assets/groovie-melting.png:/web/dist/assets/images/groovie-melting.png:ro",
          "/srv/authentik/assets/groovie-background.jpg:/web/dist/assets/images/flow_background.jpg:ro",
          "/srv/authentik/assets/custom.css:/web/dist/custom.css:ro",
        ]
      }

      template {
        data        = <<EOF
{{ with nomadVar "nomad/jobs/authentik" -}}
AUTHENTIK_SECRET_KEY={{ .AUTHENTIK_SECRET_KEY }}
AUTHENTIK_POSTGRESQL__PASSWORD={{ .AUTHENTIK_POSTGRESQL__PASSWORD }}
{{- end }}
EOF
        destination = "secrets/authentik.env"
        env         = true
      }

      env {
        AUTHENTIK_POSTGRESQL__HOST = "127.0.0.1"
        AUTHENTIK_POSTGRESQL__PORT = "5432"
        AUTHENTIK_POSTGRESQL__NAME = "authentik"
        AUTHENTIK_POSTGRESQL__USER = "authentik"
        AUTHENTIK_REDIS__HOST      = "127.0.0.1"
        AUTHENTIK_REDIS__DB        = "1"
        AUTHENTIK_EMAIL__HOST      = "smtp-relay.groovie.org"
        AUTHENTIK_EMAIL__PORT      = "25"
        AUTHENTIK_EMAIL__USE_TLS   = "false"
        AUTHENTIK_EMAIL__USE_SSL   = "false"
        AUTHENTIK_EMAIL__FROM      = "Authentik <homestar@groovie.org>"
      }

      resources {
        cpu        = 2000
        memory     = 1024
        memory_max = 2048
      }
    }

    task "worker" {
      driver = "docker"

      config {
        image        = "ghcr.io/goauthentik/server:2026.2.2"
        network_mode = "host"
        args         = ["worker"]
      }

      template {
        data        = <<EOF
{{ with nomadVar "nomad/jobs/authentik" -}}
AUTHENTIK_SECRET_KEY={{ .AUTHENTIK_SECRET_KEY }}
AUTHENTIK_POSTGRESQL__PASSWORD={{ .AUTHENTIK_POSTGRESQL__PASSWORD }}
{{- end }}
EOF
        destination = "secrets/authentik.env"
        env         = true
      }

      env {
        AUTHENTIK_POSTGRESQL__HOST = "127.0.0.1"
        AUTHENTIK_POSTGRESQL__PORT = "5432"
        AUTHENTIK_POSTGRESQL__NAME = "authentik"
        AUTHENTIK_POSTGRESQL__USER = "authentik"
        AUTHENTIK_REDIS__HOST      = "127.0.0.1"
        AUTHENTIK_REDIS__DB        = "1"
        AUTHENTIK_EMAIL__HOST      = "smtp-relay.groovie.org"
        AUTHENTIK_EMAIL__PORT      = "25"
        AUTHENTIK_EMAIL__USE_TLS   = "false"
        AUTHENTIK_EMAIL__USE_SSL   = "false"
        AUTHENTIK_EMAIL__FROM      = "Authentik <homestar@groovie.org>"
        AUTHENTIK_SKIP_MIGRATIONS  = "true"
      }

      resources {
        cpu        = 1000
        memory     = 512
        memory_max = 1024
      }
    }
  }
}
