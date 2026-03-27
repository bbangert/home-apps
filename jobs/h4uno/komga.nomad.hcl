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
spring:
  security:
    oauth2:
      client:
        registration:
          authentik:
            provider: authentik
            client-id: {{ .KOMGA_CLIENT_ID }}
            client-secret: {{ .KOMGA_CLIENT_SECRET }}
            client-name: {{ .KOMGA_CLIENT_NAME }}
            scope: openid,email
            authorization-grant-type: authorization_code
            redirect-uri: "{baseUrl}/{action}/oauth2/code/{registrationId}"
        provider:
          authentik:
            user-name-attribute: sub
            issuer-uri: https://auth.groovie.org/application/o/komga/
{{- end }}
EOF
        destination = "local/application.yml"
      }

      env {
        TZ                             = "America/Los_Angeles"
        SERVER_PORT                    = "25600"
        KOMGA_OAUTH2_ACCOUNT_CREATION  = "true"
        SPRING_CONFIG_ADDITIONAL_LOCATION = "/local/"
      }

      resources {
        cpu    = 1000
        memory = 2048
      }
    }
  }
}
