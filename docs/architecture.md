# Architecture

## Overview

The homestar cluster is a 4-node setup running Ubuntu 24.04, orchestrated by a single Nomad server. Every application runs as a Docker container managed by Nomad. There is no service mesh, no HA, and no automatic scheduling — each app is pinned to a specific node.

## Nodes

| Node | Role | IP | Key responsibilities |
|------|------|----|---------------------|
| **epyc** | Nomad server | 192.168.2.35 | Runs Nomad server, PostgreSQL, Caddy, and most central services |
| **h4uno** | Nomad client | 192.168.2.36 | Media libraries (books, comics, music), NFS server |
| **h4dos** | Nomad client | 192.168.2.39 | Plex media server, indexers (Sonarr/Radarr/etc.), NFS client |
| **beelink1** | Nomad client | 192.168.2.40 | Frigate video surveillance |

All nodes are Nomad clients. Epyc is additionally the Nomad server.

## Nomad

Nomad is configured with a single datacenter called `homestar`. All jobs use:

- **Docker driver** with host networking (`network_mode = "host"`)
- **Hostname constraints** to pin jobs to specific nodes
- **Host volumes** for persistent storage (mapped from `/srv/*` directories)
- **Nomad variables** for secrets (e.g., `nomadVar "nomad/jobs/<jobname>"`)

Job files live in `jobs/<node>/<app>.nomad.hcl`. The directory structure mirrors which node runs the app.

### Job patterns

A typical Nomad job has:

```hcl
job "appname" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "epyc"              # pins to a specific node
  }

  group "appname" {
    network {
      mode = "host"
      port "http" { static = 8080 }  # direct port binding
    }

    volume "config" {
      type   = "host"
      source = "appname-config"       # declared in host_vars
    }

    task "appname" {
      driver = "docker"
      config {
        image        = "org/image:1.2.3"  # always pinned to a specific version
        network_mode = "host"
        ports        = ["http"]
      }
      volume_mount {
        volume      = "config"
        destination = "/config"
      }
      env { ... }
      resources {
        cpu    = 500
        memory = 512
      }
    }
  }
}
```

Most apps using linuxserver.io images set `PUID`/`PGID` environment variables instead of the `user` block — linuxserver containers run as root and drop privileges internally.

## Ansible

Ansible handles all host-level configuration. The main playbook is `playbooks/site.yml`, which applies roles in order:

1. **base** — OS packages, static networking (netplan), SSH keys, UFW firewall, unattended upgrades
2. **docker** — Docker daemon
3. **onepassword** — 1Password CLI (epyc only)
4. **nfs** — NFS server on h4uno, client on h4dos
5. **nomad** — Server on epyc, client on all nodes, host volume declarations
6. **postgres** — PostgreSQL 16 on epyc, database/role creation
7. **caddy** — Reverse proxy on epyc, Caddyfile from `caddy_routes`
8. **cloudflare-dns** — CNAME records for public apps (runs locally)
9. **restic** — Backup scripts and cron schedules on all nodes
10. **telegraf** — Metrics collection on all nodes
11. **opnsense-dns** — Unbound host overrides (runs locally)

### Variable hierarchy

- `group_vars/all.yml` — Shared settings: domains, app list, 1Password references, Nomad datacenter
- `host_vars/<node>.yml` — Per-node: IP addresses, firewall ports, Nomad host volumes, Caddy routes, role-specific toggles

## Networking

### Static IPs

All nodes have static IPs assigned via netplan, managed by the `base` role. Epyc has a secondary IP (`192.168.2.202`) for the Unifi controller.

### Firewall

UFW is enabled on all nodes. The `base` role opens SSH (22) and Nomad ports (4646, 4647, 4648) by default, plus any ports listed in `base_extra_firewall_ports` in the node's host_vars.

### DNS

- **Internal:** The opnSense router (`192.168.2.1`) serves DNS. The `opnsense-dns` role creates Unbound host overrides so `*.groovie.org` and `*.ofcode.org` resolve to Caddy on epyc (`192.168.2.35`).
- **External:** The `cloudflare-dns` role creates CNAME records for apps in the `public_apps` list, pointing to the Cloudflare tunnel.

### Reverse proxy

Caddy runs on epyc and handles TLS termination for all apps. Routes are defined in `host_vars/epyc.yml` under `caddy_routes`. For apps running on other nodes, the route points to that node's IP and port.

### External access

A `cloudflared` tunnel runs on epyc and routes external traffic to Caddy. Only apps listed in `public_apps` in `group_vars/all.yml` are accessible from outside the network.

## Storage

### Host volumes

App data lives in `/srv/<app>/` directories on each node. These are declared as Nomad host volumes in `host_vars/<node>.yml` under `nomad_host_volumes`, and mounted into containers via `volume` and `volume_mount` blocks in the job file.

### NFS

h4uno exports `/srv/data` over NFS. h4dos mounts it at `/mnt/media`. This gives Plex and the indexers (Sonarr, Radarr, Lidarr) on h4dos access to the media library stored on h4uno.

### Databases

PostgreSQL 16 runs on epyc. Apps that need a database (Authentik, Immich, Sonarr, Radarr, Lidarr, Prowlarr, Linkwarden) connect via `localhost` since they also run on epyc, or use the epyc IP for remote nodes. Database creation and role grants are handled by the `postgres` role.

Immich has its own dedicated PostgreSQL instance (with pgvecto.rs) running as a Nomad job, separate from the shared PostgreSQL server.

## Secrets

Secrets are managed through two mechanisms:

- **Ansible time:** The `op read` command (1Password CLI) is called locally during playbook runs to inject secrets into templates (e.g., restic passwords, Cloudflare API tokens).
- **Nomad runtime:** Nomad variables (`nomadVar`) are used in job templates for app secrets (e.g., Authentik keys, Pushover credentials). These are set manually via `nomad var put`.

Nothing secret is stored in the repository.

## Monitoring

### Metrics pipeline

```
Telegraf (all nodes) → VictoriaMetrics (epyc:8428) → Grafana (epyc:3001)
```

Telegraf collects: CPU, memory, disk, disk I/O, network, system load, processes, systemd unit status, Docker container stats, and restic backup age. On epyc it additionally collects PostgreSQL and Nomad metrics. On h4uno and h4dos it collects Intel GPU metrics.

### Alerting

Grafana alert rules are provisioned via YAML templates in the Grafana Nomad job. Alerts route to Pushover via a provisioned contact point. Current alerts:

- Disk usage > 85%
- Memory usage > 90%
- Node down (per-node, fires on missing metrics)
- High load average (5min > 8)
- Systemd service failed (telegraf, nomad, docker)
- NFS mount unavailable
- Restic backup older than 48 hours
- Container memory > 90% of limit

## Backups

Restic runs on all nodes via a cron job deployed by the `restic` role.

| Node | S3 | B2 | What's backed up |
|------|----|----|-----------------|
| epyc | Yes | No | `/srv` (all app data) |
| h4uno | Yes | Yes (music only) | `/srv` excluding music to S3; music to B2 |
| h4dos | Yes | No | `/srv` excluding downloads and video |
| beelink1 | Yes | No | `/srv/frigate/config` only |

The backup script writes a timestamp to `/var/lib/restic-last-backup` on success. Telegraf reads this to report backup age, and Grafana alerts if it exceeds 48 hours.
