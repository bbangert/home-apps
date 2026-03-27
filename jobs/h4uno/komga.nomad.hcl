job "komga" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "h4uno"
  }

  group "komga" {
    network {
      mode = "host"
      port "http" { static = 25600 }
    }

    volume "config" {
      type      = "host"
      source    = "komga-config"
      read_only = false
    }

    volume "assets" {
      type      = "host"
      source    = "komga-assets"
      read_only = false
    }

    volume "books" {
      type      = "host"
      source    = "data-books"
      read_only = true
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "komga" {
      driver = "docker"

      config {
        image        = "gotson/komga:1.24.1"
        network_mode = "host"
        ports        = ["http"]
      }

      volume_mount {
        volume      = "config"
        destination = "/config"
      }

      volume_mount {
        volume      = "assets"
        destination = "/assets"
      }

      volume_mount {
        volume      = "books"
        destination = "/books"
        read_only   = true
      }

      template {
        data        = <<EOF
{{ with nomadVar "nomad/jobs/komga" -}}
KOMGA_OAUTH2_ACCOUNT_CREATION=true
SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_AUTHENTIK_PROVIDER=authentik
SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_AUTHENTIK_CLIENT_ID={{ .KOMGA_CLIENT_ID }}
SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_AUTHENTIK_CLIENT_SECRET={{ .KOMGA_CLIENT_SECRET }}
SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_AUTHENTIK_CLIENT_NAME={{ .KOMGA_CLIENT_NAME }}
SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_AUTHENTIK_SCOPE=openid,email
SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_AUTHENTIK_AUTHORIZATION_GRANT_TYPE=authorization_code
SPRING_SECURITY_OAUTH2_CLIENT_REGISTRATION_AUTHENTIK_REDIRECT_URI={baseUrl}/{action}/oauth2/code/{registrationId}
SPRING_SECURITY_OAUTH2_CLIENT_PROVIDER_AUTHENTIK_USER_NAME_ATTRIBUTE=sub
SPRING_SECURITY_OAUTH2_CLIENT_PROVIDER_AUTHENTIK_ISSUER_URI=https://auth.groovie.org/application/o/komga/
{{- end }}
EOF
        destination = "secrets/komga.env"
        env         = true
      }

      env {
        TZ          = "America/Los_Angeles"
        SERVER_PORT = "25600"
      }

      resources {
        cpu    = 1000
        memory = 2048
      }
    }
  }
}
