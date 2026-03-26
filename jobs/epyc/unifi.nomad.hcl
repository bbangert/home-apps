job "unifi" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "epyc"
  }

  group "unifi" {
    network {
      mode = "host"
      port "web"       { static = 8443 }
      port "inform"    { static = 8080 }
      port "stun"      { static = 3478 }
      port "discovery" { static = 10001 }
      port "syslog"    { static = 5514 }
      port "speedtest" { static = 6789 }
      port "portal-https" { static = 8843 }
      port "portal-http"  { static = 8880 }
    }

    volume "config" {
      type      = "host"
      source    = "unifi-config"
      read_only = false
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "unifi" {
      driver = "docker"

      config {
        image        = "jacobalberty/unifi:v10.0.162"
        network_mode = "host"
        ports        = ["web", "inform", "stun", "discovery", "syslog", "speedtest", "portal-https", "portal-http"]
      }

      volume_mount {
        volume      = "config"
        destination = "/unifi"
      }

      env {
        RUNAS_UID0         = "false"
        UNIFI_UID          = "999"
        UNIFI_GID          = "999"
        UNIFI_STDOUT       = "true"
        JVM_MAX_HEAP_SIZE  = "1024M"
      }

      resources {
        cpu    = 1000
        memory = 2048
      }
    }
  }
}
