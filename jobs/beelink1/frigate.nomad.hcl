job "frigate" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "beelink1"
  }

  group "frigate" {
    network {
      mode = "host"
      port "http"   { static = 5000 }
      port "rtsp"   { static = 8554 }
      port "webrtc" { static = 8555 }
    }

    volume "config" {
      type      = "host"
      source    = "frigate-config"
      read_only = false
    }

    volume "media" {
      type      = "host"
      source    = "frigate-media"
      read_only = false
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "frigate" {
      driver = "docker"

      config {
        image        = "ghcr.io/blakeblackshear/frigate:0.17.1"
        network_mode = "host"
        ports        = ["http", "rtsp", "webrtc"]
        privileged   = true
        shm_size     = 268435456
        volumes = [
          "/dev/bus/usb:/dev/bus/usb",
          "/dev/dri:/dev/dri",
        ]
        mount {
          type     = "tmpfs"
          target   = "/tmp/cache"
          tmpfs_options {
            size = 1073741824
          }
        }
      }

      volume_mount {
        volume      = "config"
        destination = "/config"
      }

      volume_mount {
        volume      = "media"
        destination = "/media"
      }

      template {
        data        = <<EOF
{{ with nomadVar "nomad/jobs/frigate" -}}
FRIGATE_MQTT_USERNAME={{ .FRIGATE_MQTT_USERNAME }}
FRIGATE_MQTT_PASSWORD={{ .FRIGATE_MQTT_PASSWORD }}
FRIGATE_REO_USERNAME={{ .FRIGATE_REO_USERNAME }}
FRIGATE_REO_PASSWORD={{ .FRIGATE_REO_PASSWORD }}
{{- end }}
FRIGATE_RTSP_PASSWORD=unused
EOF
        destination = "secrets/frigate.env"
        env         = true
      }

      resources {
        cpu        = 2000
        memory     = 1536
        memory_max = 4096
      }
    }
  }
}
