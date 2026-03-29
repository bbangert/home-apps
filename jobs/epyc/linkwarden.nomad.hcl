job "linkwarden" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "epyc"
  }

  group "linkwarden" {
    network {
      mode = "host"
      port "http" { static = 3000 }
    }

    volume "config" {
      type      = "host"
      source    = "linkwarden-config"
      read_only = false
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "linkwarden" {
      driver = "docker"

      config {
        image        = "ghcr.io/linkwarden/linkwarden:v2.14.0"
        network_mode = "host"
        ports        = ["http"]
      }

      volume_mount {
        volume      = "config"
        destination = "/data/config"
      }

      template {
        data        = <<EOF
{{ with nomadVar "nomad/jobs/linkwarden" -}}
DATABASE_URL=postgresql://{{ .POSTGRES_USER }}:{{ .POSTGRES_PASS }}@127.0.0.1:5432/linkwarden
NEXTAUTH_SECRET={{ .NEXTAUTH_SECRET }}
AUTHENTIK_CLIENT_ID={{ .OAUTH_CLIENT_ID }}
AUTHENTIK_CLIENT_SECRET={{ .OAUTH_CLIENT_SECRET }}
AUTHENTIK_ISSUER={{ .OAUTH_ISSUER }}
OPENAI_API_KEY={{ .OPENAI_API_KEY }}
{{- end }}
EOF
        destination = "secrets/linkwarden.env"
        env         = true
      }

      env {
        NEXT_PUBLIC_AUTHENTIK_ENABLED    = "true"
        NEXT_PUBLIC_DISABLE_REGISTRATION = "true"
        NEXT_PUBLIC_CREDENTIALS_ENABLED  = "false"
        DISABLE_NEW_SSO_USERS            = "false"
        NEXTAUTH_URL                     = "https://link.groovie.org/api/v1/auth"
        OPENAI_MODEL                     = "gpt-4o"
        STORAGE_FOLDER                   = "config"
        HOME                             = "/data/config"
      }

      resources {
        cpu        = 1000
        memory     = 1024
        memory_max = 2048
      }
    }
  }
}
