<div align="center">

### My Home Operations Repository

_... managed with Ansible, Nomad, and Renovate_ 🤖

</div>

---

## 📖 Overview

This is a mono repository for my home infrastructure and Nomad cluster. I try to adhere to Infrastructure as Code (IaC) and GitOps practices using [Ansible](https://www.ansible.com/) for host configuration, [Nomad](https://www.nomadproject.io/) for container orchestration, and [Renovate](https://github.com/renovatebot/renovate) for automated dependency updates.

---

## 🚀 Getting Started

### Prerequisites

Install the following on your local machine:

- **Ansible** — for host configuration and playbook runs
- **Nomad CLI** — for deploying and managing jobs
- **1Password CLI (`op`)** — for secrets (required by restic, postgres, cloudflare-dns, and opnsense-dns roles)

### Setup

1. Clone the repo:
   ```bash
   git clone git@github.com:bbangert/home-apps.git
   cd home-apps
   ```

2. Install Ansible collections:
   ```bash
   ansible-galaxy collection install -r requirements.yml
   ```

3. Ensure the SSH key is in place — Ansible is configured to use `~/.ssh/id_ed25519_homestar`:
   ```bash
   ls ~/.ssh/id_ed25519_homestar
   ```

4. Sign into 1Password CLI (needed for playbooks that read secrets):
   ```bash
   eval $(op signin)
   ```

5. Set the Nomad address and ACL token for deploying jobs:
   ```bash
   export NOMAD_ADDR=http://192.168.2.35:4646
   export NOMAD_TOKEN=<your-operator-token>  # from 1Password
   ```

### Verify

```bash
# Test Ansible connectivity to all nodes
ansible all -m ping

# Test Nomad connectivity
nomad server members
```

---

## ⛵ Cluster

### Installation

All nodes run Ubuntu 24.04 and are provisioned from bare metal using Ansible. Nomad runs as a single-server cluster with three client nodes. Each app is pinned to a specific node via hostname constraints — there is no service mesh or HA.

### Core Components

- [Nomad](https://www.nomadproject.io/): Container orchestration using the Docker driver with host networking.
- [Caddy](https://caddyserver.com/): Reverse proxy with automatic TLS via the Cloudflare DNS plugin.
- [cloudflared](https://github.com/cloudflare/cloudflared): Cloudflare tunnel for external access without port forwarding.
- [PostgreSQL](https://www.postgresql.org/): Shared database server on epyc for apps that need relational storage.
- [Valkey](https://valkey.io/): Redis-compatible cache used by Authentik and Immich.
- [VictoriaMetrics](https://victoriametrics.com/): Time-series metrics store, receives data from Telegraf agents on all nodes.
- [Grafana](https://grafana.com/): Dashboards and alerting with Pushover notifications.
- [Telegraf](https://www.influxdata.com/time-series-platform/telegraf/): Metrics collection agent deployed on every node.
- [Restic](https://restic.net/): Encrypted backups to AWS S3 and Backblaze B2.
- [1Password CLI](https://developer.1password.com/docs/cli/): Secrets are read from 1Password vaults at deploy time — nothing is stored in the repo.

### Automation

[Renovate](https://github.com/renovatebot/renovate) watches the repository for Docker image updates in `.nomad.hcl` files. When updates are found, a PR is automatically created. After merging, the updated job is deployed manually with `nomad job run`.

Unattended security upgrades are enabled on all nodes via `apt` — hosts auto-reboot at 4:00 AM if required.

### Directories

```sh
📁 homstar-cluster
├─📁 inventories/production   # Host inventory, group vars, per-host vars
├─📁 playbooks                # bootstrap.yml (first run) and site.yml (ongoing)
├─📁 roles                    # Ansible roles for OS baseline through app support
├─📁 jobs                     # Nomad job files, organized by node
│ ├─📁 epyc                   # Central services, databases, monitoring
│ ├─📁 h4uno                  # Media libraries (books, comics, music)
│ ├─📁 h4dos                  # Media server & indexers (Plex, Sonarr, etc.)
│ └─📁 beelink1               # Frigate (video surveillance)
├─📁 docs                     # Architecture, operations, and guides
└─📁 scripts                  # Legacy migration helpers
```

### Ansible Roles

| Role | Purpose |
|------|---------|
| **base** | OS packages, static networking, SSH keys, UFW firewall, unattended upgrades |
| **docker** | Docker daemon installation and configuration |
| **nomad** | Nomad server/client install, host volume declarations |
| **postgres** | PostgreSQL 16 server, database and role creation |
| **caddy** | Caddy reverse proxy with Cloudflare DNS plugin |
| **nfs** | NFS server (h4uno) and client (h4dos) configuration |
| **onepassword** | 1Password CLI installation |
| **cloudflare-dns** | CNAME records for publicly accessible apps |
| **opnsense-dns** | Unbound host overrides on the opnSense router |
| **restic** | Backup scripts and schedules for S3, B2, and local repos |
| **telegraf** | Metrics collection: system, Docker, PostgreSQL, Nomad, Intel GPU |

---

## ☁️ Cloud Dependencies

| Service | Use | Cost |
|---------|-----|------|
| [1Password](https://1password.com/) | Secrets management via CLI | ~$65/yr |
| [Cloudflare](https://www.cloudflare.com/) | Domain, DNS, tunnel for external access | ~$30/yr |
| [AWS S3](https://aws.amazon.com/s3/) | Primary off-site Restic backups | ~$5/yr |
| [Backblaze B2](https://www.backblaze.com/cloud-storage) | Media backup (music library) | ~$10/yr |
| [GitHub](https://github.com/) | Repository hosting, Renovate integration | Free |
| | | **Total: ~$9/mo** |

---

## 🌐 Networking

### Ingress

External access is provided by a [Cloudflare tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) running on epyc. Only apps listed in `public_apps` are routed through the tunnel — everything else is internal only.

### Internal DNS

The opnSense router at `192.168.2.1` serves as the internal DNS server. The `opnsense-dns` Ansible role creates Unbound host overrides so all `*.groovie.org` and `*.ofcode.org` names resolve to the Caddy reverse proxy on epyc.

### Reverse Proxy

Caddy runs on epyc and terminates TLS for all apps. Routes are defined in `host_vars/epyc.yml` under `caddy_routes` and map hostnames to backend addresses — either `localhost` for apps on epyc, or the IP of the target node for remote apps.

---

## 🔧 Hardware

| Device | IP | Role | OS Disk | RAM | Purpose |
|--------|----|------|---------|-----|---------|
| Supermicro 5019D-FTN4 (epyc) | 192.168.2.35 | Nomad server | 4 TB NVMe + 2 TB SATA | 128 GB | Central services, databases, monitoring |
| ODroid H4 (h4uno) | 192.168.2.36 | Nomad client | 2 TB NVMe | 32 GB | Media libraries, NFS server |
| ODroid H4 (h4dos) | 192.168.2.39 | Nomad client | 2 TB NVMe | 32 GB | Plex, indexers, NFS client |
| Beelink N5095 (beelink1) | 192.168.2.40 | Nomad client | 2 TB SATA | 8 GB | Frigate surveillance |
| Protectli VP2420 | 192.168.2.1 | Router | 128 GB NVMe | 32 GB | opnSense |
| CyberPower OL1500RTXL2U | — | UPS | — | — | Battery backup |
| QNAP QSW-M3216R-8S8T | — | Switch | — | — | Core 10Gb switch |
| Unifi USW-16-POE | — | Switch | — | — | PoE switch |

---

## 📦 Apps

| App | Node | Port | Description |
|-----|------|------|-------------|
| [Authentik](https://goauthentik.io/) | epyc | 9000 | Identity provider, SSO/OAuth2 |
| [Immich](https://immich.app/) | epyc | 2283 | Photo & video library |
| [ownCloud Infinite Scale](https://owncloud.dev/ocis/) | epyc | 9200 | File sync & sharing |
| [Grafana](https://grafana.com/) | epyc | 3001 | Dashboards & alerting |
| [VictoriaMetrics](https://victoriametrics.com/) | epyc | 8428 | Metrics storage |
| [Valkey](https://valkey.io/) | epyc | 6379 | Redis-compatible cache |
| [Caddy](https://caddyserver.com/) | epyc | 443 | Reverse proxy |
| [cloudflared](https://github.com/cloudflare/cloudflared) | epyc | — | Cloudflare tunnel |
| [Vaultwarden](https://github.com/dani-garcia/vaultwarden) | epyc | 8081 | Password manager |
| [Linkwarden](https://linkwarden.app/) | epyc | 3000 | Bookmark manager |
| [FreshRSS](https://freshrss.org/) | epyc | 8082 | RSS reader |
| [The Lounge](https://thelounge.chat/) | epyc | 9090 | IRC client |
| [Duke To Go](https://github.com/bbangert/duketogo) | epyc | 8888 | URL shortener |
| [Paste](https://github.com/bbangert/paste) | epyc | 6543 | Pastebin |
| [Unifi Controller](https://ui.com/) | epyc | 8443 | Network management |
| [SMTP Relay](https://github.com/bbangert/smtp-relay) | epyc | 25 | Mail relay |
| [Plex](https://www.plex.tv/) | h4dos | 32400 | Media server (Intel QuickSync HW transcoding) |
| [Komga](https://komga.org/) | h4uno | 25600 | Comic/manga reader |
| [Komf](https://github.com/Snd-R/Komf) | h4uno | 8085 | Komga metadata fetcher |
| [Calibre-Web](https://github.com/janeczku/calibre-web) | h4uno | 8083 | Ebook reader |
| [Music Assistant](https://music-assistant.io/) | h4uno | 8095 | Music streaming |
| [Frigate](https://frigate.video/) | beelink1 | 5000 | Video surveillance with object detection |

---

## 📜 Documentation

| Document | Description |
|----------|-------------|
| [Architecture](docs/architecture.md) | How the cluster is structured: nodes, networking, storage, DNS, secrets, monitoring, backups |
| [Operations](docs/operations.md) | Day-to-day runbook: deploying apps, running playbooks, troubleshooting |
| [Adding an App](docs/adding-an-app.md) | Step-by-step guide for deploying a new application |
| [Migration](docs/migration.md) | Historical record of the Talos/Kubernetes to Nomad migration |
