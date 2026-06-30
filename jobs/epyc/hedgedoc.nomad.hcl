job "hedgedoc" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "epyc"
  }

  group "hedgedoc" {
    network {
      mode = "host"
      port "http" { static = 3300 }
    }

    volume "uploads" {
      type      = "host"
      source    = "hedgedoc-uploads"
      read_only = false
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "hedgedoc" {
      driver = "docker"

      config {
        image        = "quay.io/hedgedoc/hedgedoc:1.11.0"
        network_mode = "host"
        ports        = ["http"]
      }

      volume_mount {
        volume      = "uploads"
        destination = "/hedgedoc/public/uploads"
      }

      template {
        data        = <<EOF
{{ with nomadVar "nomad/jobs/hedgedoc" -}}
CMD_DB_URL=postgres://{{ .POSTGRES_USER }}:{{ .POSTGRES_PASSWORD }}@127.0.0.1:5432/hedgedoc
CMD_SESSION_SECRET={{ .SESSION_SECRET }}
CMD_OAUTH2_CLIENT_ID={{ .OAUTH_CLIENT_ID }}
CMD_OAUTH2_CLIENT_SECRET={{ .OAUTH_CLIENT_SECRET }}
{{- end }}
EOF
        destination = "secrets/hedgedoc.env"
        env         = true
      }

      env {
        # Listen / proxy
        CMD_PORT            = "3300"
        CMD_DOMAIN          = "notes.groovie.org"
        CMD_PROTOCOL_USESSL = "true"
        CMD_URL_ADDPORT     = "false"

        # Uploads on the host volume
        CMD_IMAGE_UPLOAD_TYPE = "filesystem"

        # Authentik OAuth2 only — no local accounts, no anonymous notes
        CMD_EMAIL                                 = "false"
        CMD_ALLOW_EMAIL_REGISTER                  = "false"
        CMD_ALLOW_ANONYMOUS                       = "false"
        CMD_DEFAULT_PERMISSION                    = "limited"
        CMD_OAUTH2_PROVIDERNAME                   = "Authentik"
        CMD_OAUTH2_SCOPE                          = "openid email profile"
        CMD_OAUTH2_AUTHORIZATION_URL              = "https://auth.groovie.org/application/o/authorize/"
        CMD_OAUTH2_TOKEN_URL                      = "https://auth.groovie.org/application/o/token/"
        CMD_OAUTH2_USER_PROFILE_URL               = "https://auth.groovie.org/application/o/userinfo/"
        CMD_OAUTH2_USER_PROFILE_USERNAME_ATTR     = "preferred_username"
        CMD_OAUTH2_USER_PROFILE_DISPLAY_NAME_ATTR = "name"
        CMD_OAUTH2_USER_PROFILE_EMAIL_ATTR        = "email"
      }

      resources {
        cpu        = 500
        memory     = 512
        memory_max = 1024
      }
    }
  }
}
