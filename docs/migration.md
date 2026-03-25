# Homestar Migration: Kubernetes (Talos) → Ansible + Nomad

## Philosophy

Keep it simple. No service mesh, no distributed storage, no control plane quorum.
Each app is manually assigned to a specific node. Nomad ensures the containers
stay running and provides a clean job-spec format for configuration. If a node
goes down, its apps are down until the node comes back — that's fine for a homelab.

---

## Current state

**Cluster name:** homestar
**Current OS:** Talos v1.8.4 / Kubernetes v1.31.6
**GitOps:** Flux + Renovate
**Storage:** Longhorn (distributed block), OpenEBS (hostpath)
**Secrets:** External Secrets + 1Password Connect
**Ingress:** ingress-nginx + Cloudflare tunnel (cloudflared)
**Backups:** CNPG Barman to S3 (`s3://homestar-cloudnative-pg/`) — intact, VolSync (non-functional)

### Physical machines (4)

| Name | Hardware | CPU | Disk | RAM | Notes |
|------|----------|-----|------|-----|-------|
| epyc | Supermicro 5019D-FTN4 | AMD EPYC 3251 8C/16T @ 2.5-3.1GHz | 4TB NVMe (new) + 2TB SATA SSD | 128GB | No iGPU. Currently runs talos1+talos2 VMs under Proxmox. Will be wiped to bare metal. |
| h4uno | ODroid H4 | Intel N97 4C/4T @ 2.0-3.6GHz | 2TB NVMe | 32GB | Quick Sync (HW transcode for Plex) |
| h4dos | ODroid H4 | Intel N97 4C/4T @ 2.0-3.6GHz | 2TB NVMe | 32GB | Quick Sync |
| beelink1 | Beelink Mini S | Intel N5095 4C/4T @ 2.0-2.9GHz | 2TB SATA SSD | 8GB | Coral TPU + Intel GPU for Frigate |

### Databases

**Shared PostgreSQL 16** (CNPG, 3 instances, backs up via Barman to S3):
- authentik, atuin, freshrss, lidarr (main+log), linkwarden, prowlarr, radarr (main+log), sonarr (main+log), vaultwarden, windmill
- **⚠️ Currently down** — was running on talos1 (volume full). Data intact in Barman S3 backups.

**Immich PostgreSQL 16** (separate, pgvecto.rs extension, backs up via Barman to S3):
- immich
- **⚠️ Currently down** — same reason. Data intact in Barman S3 backups.

**Dragonfly** (Redis-compatible, ephemeral, used by Authentik)

---

## Target state

### Architecture

```
                    ┌─────────────────────────────────┐
                    │         Cloudflare Tunnel        │
                    └──────────────┬───────────────────┘
                                   │
    ┌──────────────────────────────┼──────────────────────────────┐
    │                              │                              │
┌───┴──────────┐      ┌───────────┴──────┐      ┌───────────────┐
│    epyc      │      │     h4uno        │      │    h4dos      │
│  128GB/EPYC  │      │  32GB/N97        │      │  32GB/N97     │
│  4TB+2TB     │      │  2TB NVMe        │      │  2TB NVMe     │
├──────────────┤      ├──────────────────┤      ├───────────────┤
│ Nomad server │      │ Nomad client     │      │ Nomad client  │
├──────────────┤      ├──────────────────┤      ├───────────────┤
│ Postgres 17  │      │ Plex             │      │ Sonarr        │
│ Immich+PG+ML │      │ Komga + Komf     │      │ Radarr        │
│ Authentik    │      │ Calibre-Web      │      │ Lidarr        │
│ Dragonfly    │      │ OCIS             │      │ SABnzbd       │
│ Windmill     │      │ Music Assistant  │      │ Prowlarr      │
│ Linkwarden   │      │ Beszel hub       │      │               │
│ FreshRSS     │      │                  │      │               │
│ Atuin        │      │                  │      │               │
│ TheLounge    │      │                  │      │               │
│ Unifi        │      │                  │      │               │
│ Vaultwarden  │      │                  │      │               │
│ DukeTogo     │      │                  │      │               │
│ Paste        │      │                  │      │               │
│ SMTP Relay   │      │                  │      │               │
│ Caddy        │      │                  │      │               │
│ Cloudflared  │      │                  │      │               │
└──────────────┘      └──────────────────┘      └───────────────┘

┌───────────────┐
│   beelink1    │
│  8GB/N5095    │
│  2TB SATA     │
├───────────────┤
│ Nomad client  │
├───────────────┤
│ Frigate       │
│ (Coral+GPU)   │
└───────────────┘

    All nodes also run: Dozzle (container log viewer)
    and Beszel agent (metrics collection)
```

### Node assignments

Apps are pinned to nodes based on resource needs and data locality.

**epyc** — Heavy compute + all databases (Nomad server + client)
- PostgreSQL 17 (host, via apt) — shared instance for all app databases
- Immich Postgres (Docker, via Nomad) — Immich's official image with VectorChord, port 5433
- Immich — photo library + ML inference (memory/CPU intensive)
- Authentik — SSO (server + worker)
- Dragonfly — Redis-compatible cache
- Windmill — workflow execution (can be CPU-heavy)
- Vaultwarden — password vault (Postgres-backed)
- Linkwarden, FreshRSS, Atuin — Postgres-backed, lightweight
- TheLounge, Unifi Controller — small config volumes
- DukeTogo, Paste, SMTP Relay — minimal/stateless
- Caddy reverse proxy + Cloudflared tunnel

**h4uno** — Media serving + libraries (2TB NVMe, NFS server for media, Intel N97 Quick Sync for Plex transcoding)
- `/srv/data/` — single root exported via NFS, contains:
  - `downloads/` (200Gi) — SABnzbd writes here (via NFS from h4dos)
  - `video/` (450Gi) — Sonarr/Radarr hard-link from downloads (via NFS from h4dos)
  - `music/` (550Gi) — Lidarr hard-links from downloads (via NFS from h4dos)
  - `books/` — local only, not exported
- Plex — config (local) + reads video/music directly from `/srv/data/` (NVMe speed)
- Komga + Komf — comic/book library
- Calibre-Web — config + `/srv/data/books/`
- OCIS — ownCloud files
- Music Assistant — config + reads `/srv/data/music/`
- Beszel hub — monitoring dashboards (agents on all nodes)

**h4dos** — Download automation (mounts h4uno:/srv/data via NFS)
- `/mnt/data/` — NFS mount of h4uno:/srv/data (downloads + media as one filesystem, hard-links work)
- SABnzbd — config (local) + writes to `/mnt/data/downloads/`
- Sonarr — config (local); hard-links from `/mnt/data/downloads/` → `/mnt/data/video/`; Postgres on epyc
- Radarr — config (local); hard-links from `/mnt/data/downloads/` → `/mnt/data/video/`; Postgres on epyc
- Lidarr — config (local); hard-links from `/mnt/data/downloads/` → `/mnt/data/music/`; Postgres on epyc
- Prowlarr — Postgres on epyc

**beelink1** — NVR (hardware-specific)
- Frigate — needs Coral TPU + Intel GPU, config + media

### Nomad topology

Minimal setup — Nomad as a container runner, not an orchestrator:

- **epyc**: Nomad server (single server, no quorum needed) + client
- **h4uno, h4dos, beelink1**: Nomad clients only
- **No Consul** — services find Postgres/Dragonfly via static IPs, not service discovery
- If epyc goes down: existing containers on other nodes keep running (Nomad client is autonomous). You just can't deploy changes until epyc is back. Postgres-dependent apps on other nodes will be degraded.
- Jobs use `constraint { attribute = "${attr.unique.hostname}" value = "epyc" }` to pin to nodes

### Networking

- Most apps run with Docker bridge networking, Nomad maps a unique host port per app
- Caddy on epyc handles all HTTP/HTTPS routing by hostname
- Cloudflared tunnel on epyc points to Caddy (catch-all)
- No overlay network, no service mesh, no CNI

### IP plan

| Node | Primary IP | Secondary IP | Notes |
|------|-----------|--------------|-------|
| epyc | 192.168.2.35 | 192.168.2.202 | Primary: all services + Caddy. Secondary: Unifi (avoids re-adopting devices) |
| h4uno | 192.168.2.36 | — | Plex (advertise URL), Music Assistant (mDNS), NFS server |
| h4dos | 192.168.2.39 | — | All *arr apps, no special networking |
| beelink1 | 192.168.2.40 | — | Frigate only |

**Apps requiring host networking** (can't use Docker bridge):

| App | Node | Why | Ports |
|-----|------|-----|-------|
| Unifi Controller | epyc (on .202) | Device adoption requires L2 discovery, STUN, and inform on known IP | 8080, 8443, 3478/UDP, 5514/UDP, 6789, 10001/UDP |
| Music Assistant | h4uno | mDNS/Chromecast discovery requires being on the LAN broadcast domain | 8095 |
| Plex | h4uno | Direct play needs `PLEX_ADVERTISE_URL` pointing to a reachable IP:port | 32400 (can use bridge with mapped port) |
| Frigate | beelink1 | RTSP streams need stable IP:port for cameras to connect to | 5000, 8554, 8555 |

All other apps use Docker bridge networking with Caddy proxying by hostname.

**Plex advertise URL:** `https://192.168.2.36:32400,https://plex.groovie.org:443`

**Unifi secondary IP on epyc** (netplan config):
```yaml
# /etc/netplan/01-netcfg.yaml on epyc
network:
  ethernets:
    eth0:  # adjust interface name
      addresses:
        - 192.168.2.35/24
        - 192.168.2.202/24
      routes:
        - to: default
          via: 192.168.2.1
      nameservers:
        addresses: [192.168.2.1]
```

Unifi container binds to 192.168.2.202 specifically so its ports don't conflict
with other services on .35. Existing Unifi devices continue informing to .202
with no re-adoption needed.

### DNS strategy

Two domains: `groovie.org` (primary) and `ofcode.org` (paste only).

**Public apps** get individual CNAME records in Cloudflare (managed via Ansible).
**All apps** get opnSense Unbound host overrides for LAN resolution (managed via Ansible).
Both are driven from a single `all_apps` list, with `public_apps` as a subset.

Adding a new app: add a Caddyfile block + add to `all_apps` + run the DNS playbook.
If it should be public, also add it to `public_apps`.

**App list and DNS roles (both Cloudflare + opnSense from one config):**

```yaml
# group_vars/all.yml
tunnel_id: "your-tunnel-id"
caddy_ip: "192.168.2.35"

all_apps:
  - { zone: groovie.org, name: auth }
  - { zone: groovie.org, name: photos }
  - { zone: groovie.org, name: files }
  - { zone: groovie.org, name: plex }
  - { zone: groovie.org, name: link }
  - { zone: groovie.org, name: sh }
  - { zone: groovie.org, name: music-assistant }
  - { zone: groovie.org, name: sonarr }
  - { zone: groovie.org, name: radarr }
  - { zone: groovie.org, name: lidarr }
  - { zone: groovie.org, name: prowlarr }
  - { zone: groovie.org, name: sabnzbd }
  - { zone: groovie.org, name: komga }
  - { zone: groovie.org, name: calibre-web }
  - { zone: groovie.org, name: freshrss }
  - { zone: groovie.org, name: thelounge }
  - { zone: groovie.org, name: vaultwarden }
  - { zone: groovie.org, name: unifi }
  - { zone: groovie.org, name: frigate }
  - { zone: groovie.org, name: beszel }
  - { zone: groovie.org, name: windmill }
  - { zone: ofcode.org, name: paste }

public_apps:
  - { zone: groovie.org, name: auth }
  - { zone: ofcode.org, name: paste }

# roles/opnsense-dns/tasks/main.yml
- name: Internal DNS host overrides
  ansibleguy.opnsense.unbound_host:
    hostname: "{{ item.name }}"
    domain: "{{ item.zone }}"
    value: "{{ caddy_ip }}"
    description: "homestar-{{ item.name }}"
    reload: false
  loop: "{{ all_apps }}"

- name: Reload Unbound
  ansibleguy.opnsense.reload:
    target: unbound

# roles/cloudflare-dns/tasks/main.yml
- name: Public app DNS records
  community.general.cloudflare_dns:
    zone: "{{ item.zone }}"
    record: "{{ item.name }}"
    type: CNAME
    value: "{{ tunnel_id }}.cfargotunnel.com"
    proxied: true
    api_token: "{{ lookup('pipe', 'op read op://HomeCluster/cloudflare/API_TOKEN') }}"
    state: present
  loop: "{{ public_apps }}"
```

The `ansibleguy.opnsense` collection talks to the opnSense API — requires an API
key+secret created in opnSense (System → Access → Users). Connection config goes
in `module_defaults` or an API credential file.

**Cloudflared config (catch-all, tunnel only receives traffic for public DNS hostnames):**
```yaml
ingress:
  - service: https://localhost:443
    originRequest:
      originServerName: groovie.org  # validates Caddy's TLS cert
```

Cloudflared connects to Caddy's HTTPS listener. The `originServerName` tells
cloudflared which hostname to expect on the certificate.

### App visibility

Based on current k8s ingress classes (internal = default, external = Authentik only).

**Public (through Cloudflare tunnel) — have CNAME records:**
- `auth.groovie.org` — Authentik SSO
- `paste.ofcode.org` — Paste

**Internal only (LAN via opnSense host overrides, managed by Ansible) — no public DNS:**
- `photos.groovie.org` — Immich
- `files.groovie.org` — OCIS
- `plex.groovie.org` — Plex
- `link.groovie.org` — Linkwarden
- `sh.groovie.org` — Atuin
- `music-assistant.groovie.org` — Music Assistant
- `sonarr.groovie.org` — Sonarr
- `radarr.groovie.org` — Radarr
- `lidarr.groovie.org` — Lidarr
- `prowlarr.groovie.org` — Prowlarr
- `sabnzbd.groovie.org` — SABnzbd
- `komga.groovie.org` — Komga
- `calibre-web.groovie.org` — Calibre-Web
- `freshrss.groovie.org` — FreshRSS
- `thelounge.groovie.org` — TheLounge
- `vaultwarden.groovie.org` — Vaultwarden
- `unifi.groovie.org` — Unifi
- `frigate.groovie.org` — Frigate
- `beszel.groovie.org` — Beszel monitoring
- `windmill.groovie.org` — Windmill

To make an internal app public later: add it to `public_apps` in group_vars and
run the cloudflare-dns playbook. That's it — Caddy and cloudflared already handle it.

### Reverse proxy: Caddy

Caddy runs on epyc as a Nomad job (or systemd service). One Caddyfile defines all routes
for both public and internal apps. Caddy doesn't need to know the difference — the DNS
layer controls what's reachable from the internet.

**TLS is required** even though external traffic arrives via the Cloudflare tunnel:
- **External path:** Cloudflare edge → tunnel → cloudflared on epyc → Caddy (HTTPS on localhost:443)
- **Internal path:** Browser on LAN → opnSense → Caddy (HTTPS on epyc IP:443)

Without TLS, internal LAN clients would get browser warnings and unencrypted connections.
Caddy uses the Cloudflare DNS challenge (`acme_dns`) to prove domain ownership via TXT
records, so it can obtain and renew valid Let's Encrypt certificates from a private LAN
IP — no inbound ports needed.

Requires the `caddy-dns/cloudflare` plugin for DNS challenge.

**Caddyfile:**
```
{
  acme_dns cloudflare {env.CLOUDFLARE_API_TOKEN}
}

# --- groovie.org: Public (has Cloudflare CNAME) ---

auth.groovie.org {
  reverse_proxy localhost:9000
}

# --- groovie.org: Internal only (LAN via opnSense host overrides) ---

photos.groovie.org {
  reverse_proxy localhost:2283
}
files.groovie.org {
  reverse_proxy localhost:9200
}
plex.groovie.org {
  reverse_proxy h4uno:32400
}
link.groovie.org {
  reverse_proxy localhost:3000
}
sh.groovie.org {
  reverse_proxy localhost:8888
}
music-assistant.groovie.org {
  reverse_proxy h4uno:8095
}
sonarr.groovie.org {
  reverse_proxy h4dos:8989
}
radarr.groovie.org {
  reverse_proxy h4dos:7878
}
lidarr.groovie.org {
  reverse_proxy h4dos:8686
}
prowlarr.groovie.org {
  reverse_proxy h4dos:9696
}
sabnzbd.groovie.org {
  reverse_proxy h4dos:8080
}
komga.groovie.org {
  reverse_proxy h4uno:25600
}
calibre-web.groovie.org {
  reverse_proxy h4uno:8083
}
freshrss.groovie.org {
  reverse_proxy localhost:8080
}
thelounge.groovie.org {
  reverse_proxy localhost:9000
}
vaultwarden.groovie.org {
  reverse_proxy localhost:8080
}
unifi.groovie.org {
  reverse_proxy localhost:8443
}
frigate.groovie.org {
  reverse_proxy beelink1:5000
}
beszel.groovie.org {
  reverse_proxy h4uno:8090
}
windmill.groovie.org {
  reverse_proxy localhost:8000
}

# --- ofcode.org ---

paste.ofcode.org {
  reverse_proxy localhost:8080
}
```

Note: ports above are placeholders — actual ports will be assigned when writing
the Nomad job specs. Several apps on the same node can't share a port (e.g.
freshrss, vaultwarden, thelounge all on epyc can't all use 8080).

### Secrets management: 1Password CLI

Secrets stay in 1Password — same source of truth as before, just accessed directly
via the `op` CLI instead of through External Secrets + 1Password Connect.

For Nomad jobs, use `op run` to inject secrets as environment variables at deploy time:
```bash
# Deploy a job with secrets injected from 1Password
op run --env-file=.env.tpl -- nomad job run plex.nomad.hcl
```

Or use `op read` in Nomad job `template` stanzas for secrets that need to be in files:
```hcl
template {
  data        = <<EOF
DB_PASSWORD={{ env "DB_PASSWORD" }}
EOF
  destination = "secrets/db.env"
  env         = true
}
```

For Ansible, `op read` in tasks or a lookup plugin:
```yaml
- name: Set Postgres password
  set_fact:
    pg_password: "{{ lookup('pipe', 'op read op://HomeCluster/cloudnative-pg/POSTGRES_SUPER_PASS') }}"
```

### Backups (new setup)

| What | How | Where |
|------|-----|-------|
| PostgreSQL 17 (shared) | pg_dump cron (or pgBackRest) | S3 (Cloudflare R2 or Backblaze B2) |
| Immich Postgres (Docker) | pg_dump from container, separate schedule | S3 |
| App config volumes | Restic cron job per node | S3 |
| Media (music/video/books) | Restic or rclone | S3 / second drive |

Nomad periodic jobs or simple systemd timers can run the backup schedules.

---

## Pre-migration: Data backup

**Status:** 🟢 PVC backups complete. Postgres down but Barman S3 backups are intact.

### PostgreSQL databases

**⚠️ Both Postgres clusters are currently down** — they were running on talos1 which
failed (volume full). Live `pg_dump` is not possible. All data is in the Barman S3
backups at `s3://homestar-cloudnative-pg/`.

Barman server names:
- `postgres16-v5` — shared databases (authentik, atuin, freshrss, etc.)
- `immich-postgres16-v1` — Immich database

S3 credentials stored in 1Password under `aws` and `cloudnative-pg`.

**Action items (verify before wiping epyc):**
- [ ] Verify Barman backups exist and are recent:
  - `barman-cloud-backup-list --cloud-provider aws-s3 s3://homestar-cloudnative-pg/ postgres16-v5`
  - `barman-cloud-backup-list --cloud-provider aws-s3 s3://homestar-cloudnative-pg/ immich-postgres16-v1`
- [ ] Note S3 credentials from 1Password

Actual restore happens in Phase 2 after epyc is provisioned with Ubuntu + PostgreSQL.

### Longhorn PVC backup ✅ Complete

All PVC data has been backed up using `backup_pvcs.py` (rsync-based extraction from
k8s volumes). Backup data is on local disk ready for restoration to host paths.

**Critical volumes (irreplaceable):**
- [x] `immich-data` (50Gi) — photo library
- [x] `plex-config` (50Gi) — Plex database/metadata
- [x] `media-music` (550Gi) — music library
- [x] `media-video` (450Gi) — video library
- [x] `ocis-data` — ownCloud files
- [x] `vaultwarden` — password vault config
- [x] `komga-config` + `komga-assets` — comic library
- [x] `calibre-web-config` + `media-books` — book library

**App config (important, small):**
- [x] `sonarr-config`, `radarr-config`, `lidarr-config`, `sabnzbd-config`
- [x] `komf-config`, `music-assistant-config`, `duketogo-config`
- [x] `freshrss`, `linkwarden`, `thelounge`, `unifi`, `frigate`, `paste`
- [x] `sabnzbd-downloads` (200Gi) — active downloads

**Skipped (regenerable):**
- `immich-machine-learning-cache`, `plex-cache` — regenerate
- `frigate-media` — recordings, acceptable to lose

---

## Phase 1: Foundation

**Status:** 🔴 Not started

One node at a time. Start with a worker, validate, then do the rest.

### Order of operations

1. Wipe **epyc** first (already degraded — talos1 down, volume full) → Ubuntu Server 24.04 LTS bare metal + Ansible + Nomad server+client + PostgreSQL 17
2. Re-image **beelink1** → Ubuntu Server 24.04 LTS + Ansible + Nomad client → validate connects to Nomad server on epyc
3. Re-image **h4dos** → Ubuntu Server 24.04 LTS + Ansible + Nomad client → validate
4. Re-image **h4uno** last (currently running most k8s workloads) → Ubuntu Server 24.04 LTS + Ansible + Nomad client → validate
5. Restore data from backups to host paths on each node

### Ansible roles needed

- [ ] `base` — OS hardening, SSH keys, NTP, packages, firewall
- [ ] `onepassword` — 1Password CLI install + service account config (all nodes)
- [ ] `docker` — Docker CE install + daemon config
- [ ] `nomad` — Nomad binary + systemd unit (server or client role via variable)
- [ ] `nfs` — NFS server on h4uno (exports `/srv/data`), NFS client on h4dos (mounts to `/mnt/data`)
- [ ] `caddy` — Custom Caddy build with cloudflare DNS plugin (epyc only), Caddyfile
- [ ] `cloudflare-dns` — Manages CNAME records for public apps via Cloudflare API
- [ ] `opnsense-dns` — Manages Unbound host overrides for all apps via opnSense API
- [ ] `postgres` — PostgreSQL 17 install from PGDG repo (epyc only), tuned for shared node
- [ ] `monitoring` — Beszel agent on all nodes, Beszel hub on h4uno, Dozzle on all nodes
- [ ] `backup` — restic + cron schedules for volume and DB backups

### Ansible inventory

```ini
[nomad_server]
epyc     ansible_host=192.168.2.35

[nomad_client]
h4uno    ansible_host=192.168.2.36
h4dos    ansible_host=192.168.2.39
beelink1 ansible_host=192.168.2.40

[postgres]
epyc

[all:vars]
ansible_user=ben
```

### Nomad configuration

**epyc** (`/etc/nomad.d/nomad.hcl`):
```hcl
datacenter = "homestar"
data_dir   = "/opt/nomad"

server {
  enabled          = true
  bootstrap_expect = 1  # single server, no quorum
}

client {
  enabled = true
  host_volume "postgres-data"     { path = "/srv/postgres/data" }
  host_volume "immich-pg-data"    { path = "/srv/immich-pg/data" }
  host_volume "immich-data"       { path = "/srv/immich/data" }
  host_volume "vaultwarden"       { path = "/srv/vaultwarden/config" }
  # ... one host_volume per app data dir on this node
}
```

**Clients** (`h4uno`, `h4dos`, `beelink1`):
```hcl
datacenter = "homestar"
data_dir   = "/opt/nomad"

client {
  enabled = true
  servers = ["192.168.2.35:4647"]

  # h4uno example — local data root + app configs
  host_volume "data"           { path = "/srv/data"           read_only = false }
  host_volume "plex-config"    { path = "/srv/plex/config"    read_only = false }
  host_volume "komga-config"   { path = "/srv/komga/config"   read_only = false }
  # ...

  # h4dos example — NFS mount of h4uno:/srv/data + local app configs
  # host_volume "data"         { path = "/mnt/data"           read_only = false }
  # host_volume "sonarr-config" { path = "/srv/sonarr/config" read_only = false }
  # ...
}
```

### Networking setup

- [ ] epyc primary IP: 192.168.2.35 (reuse talos1's old IP)
- [ ] epyc secondary IP: 192.168.2.202 (for Unifi controller, avoids re-adopting devices)
- [ ] Configure both IPs in netplan on epyc (see Target State → IP plan)
- [ ] h4uno, h4dos, beelink1 keep current IPs (.36, .39, .40)
- [ ] opnSense: create API key for Ansible, reserve all IPs in DHCP
- [ ] opnSense DNS: run `opnsense-dns` Ansible playbook to create host overrides
- [ ] Cloudflare DNS: run `cloudflare-dns` Ansible playbook to create CNAMEs for public apps
- [ ] Cloudflared tunnel on epyc with catch-all to Caddy
- [ ] Update Plex `PLEX_ADVERTISE_URL` to `https://192.168.2.36:32400,https://plex.groovie.org:443`
- [ ] Unifi devices already inform to 192.168.2.202 — no re-adoption needed

### Target OS

Ubuntu Server 24.04 LTS — newer kernel (6.8) for better N97 Quick Sync and Coral TPU support.
PostgreSQL 17 via PGDG apt repo. Server variant (no GUI/desktop environment — headless,
managed via SSH and Ansible).

### Renovate for image updates

Renovate continues watching the repo, now scanning Nomad `.hcl` job files for
Docker image tags instead of Kubernetes HelmReleases. Renovate natively supports
HCL and Docker image references — no custom managers needed.

```hcl
# Renovate detects and updates this automatically
config {
  image = "ghcr.io/onedr0p/plex:1.41.3"  # renovate: datasource=docker
}
```

- [ ] Create new git repo for Nomad job files + Ansible + Caddyfile
- [ ] Enable Renovate on the new repo (same GitHub App as before)
- [ ] Verify Renovate detects image tags in `.hcl` files and creates PRs
- [ ] Merge PRs, then `nomad job run` to apply (manual or via CI)

---

## Phase 2: PostgreSQL + Infrastructure on epyc

**Status:** 🔴 Not started

### Restore databases from Barman S3 backups

Barman backups are physical PG16 data files — they can only restore to PG16. Since
we want PG17, restore to a temporary PG16 instance first, then pg_dump → pg_restore
into PG17.

```bash
# Step 1: Install PG16 temporarily + PG17 + barman-cli-cloud
sudo apt install postgresql-16 postgresql-17 barman-cli-cloud

# Step 2: Restore shared cluster from S3
sudo -u postgres barman-cloud-restore \
  --cloud-provider aws-s3 \
  s3://homestar-cloudnative-pg/ \
  postgres16-v5 \
  /var/lib/postgresql/16/restored

# Step 3: Start temporary PG16 on a non-default port
pg_ctlcluster 16 restored start -o "-p 5434"

# Step 4: Dump all shared databases from restored PG16
for db in authentik atuin freshrss lidarr_main lidarr_log linkwarden \
          prowlarr_main radarr_main radarr_log sonarr_main sonarr_log \
          vaultwarden windmill; do
  pg_dump -Fc -p 5434 -U postgres $db > ${db}.dump
done

# Step 5: Repeat for Immich (separate Barman backup, different server name)
sudo -u postgres barman-cloud-restore \
  --cloud-provider aws-s3 \
  s3://homestar-cloudnative-pg/ \
  immich-postgres16-v1 \
  /var/lib/postgresql/16/restored-immich

pg_ctlcluster 16 restored-immich start -o "-p 5435"
pg_dump -Fc -p 5435 -U postgres immich > immich.dump

# Step 6: Verify dumps are valid
for f in *.dump; do pg_restore --list $f > /dev/null && echo "$f OK"; done

# Step 7: Clean up temporary PG16
pg_ctlcluster 16 restored stop
pg_ctlcluster 16 restored-immich stop
sudo apt remove postgresql-16
rm -rf /var/lib/postgresql/16/
```

- [ ] Restore shared Barman backup (`postgres16-v5`)
- [ ] Restore Immich Barman backup (`immich-postgres16-v1`)
- [ ] Dump all databases from temporary PG16
- [ ] Verify all dump files
- [ ] Remove temporary PG16

### PostgreSQL 17 on epyc (shared, host-installed)

Run Postgres directly on the host for all app databases (everything except Immich).
Simple Ansible role: install from PGDG repo, drop a tuned `postgresql.conf`, create
databases/users, set up pgBackRest for backups.

Since epyc is a shared node (Nomad server, Docker containers, Caddy, etc.), tune
Postgres conservatively — don't let it assume it owns all 128GB of RAM:

```bash
# Install from PGDG repo
sudo apt install postgresql-17

# Key tuning overrides for a shared node (~12 small app databases)
# postgresql.conf
shared_buffers = 2GB
effective_cache_size = 8GB
work_mem = 64MB
maintenance_work_mem = 512MB
max_connections = 200
listen_addresses = '*'         # allow connections from other nodes
```

Databases to restore (from dump files produced in the Barman restore step above):
```bash
for db in authentik atuin freshrss lidarr_main lidarr_log linkwarden \
          prowlarr_main radarr_main radarr_log sonarr_main sonarr_log \
          vaultwarden windmill; do
  createdb -U postgres $db
  pg_restore -U postgres -d $db ${db}.dump
done
```

- [ ] authentik
- [ ] atuin
- [ ] freshrss
- [ ] lidarr_main, lidarr_log
- [ ] linkwarden
- [ ] prowlarr_main
- [ ] radarr_main, radarr_log
- [ ] sonarr_main, sonarr_log
- [ ] vaultwarden
- [ ] windmill
- [ ] Create app-specific users with appropriate permissions
- [ ] Verify each app can connect from epyc (localhost:5432) and from other nodes

### Immich PostgreSQL on epyc (separate, Dockerized via Nomad)

Immich gets its own Postgres container using Immich's official image. Rationale:
- Immich upgrades frequently and each release can change which VectorChord version
  is required, run heavy reindexing, or need Postgres config changes.
- Running against their tested image means upgrades follow their docs exactly.
- If an Immich upgrade goes sideways, only the Immich database is affected — the
  shared Postgres with 12 other databases is untouched.
- On a 128GB machine, a second Postgres instance is negligible overhead.

```hcl
# Nomad job for Immich's dedicated Postgres
job "immich-postgres" {
  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "epyc"
  }
  group "db" {
    network {
      mode = "host"
      port "pg" { static = 5433 }  # 5433 to avoid conflict with host PG on 5432
    }
    volume "data" {
      type   = "host"
      source = "immich-pg-data"
    }
    task "postgres" {
      driver = "docker"
      config {
        # Use Immich's official image — includes pgvector + VectorChord
        image        = "ghcr.io/immich-app/postgres:17-vectorchord0.5.3-pgvector0.8.1"
        network_mode = "host"
        ports        = ["pg"]
      }
      volume_mount {
        volume      = "data"
        destination = "/var/lib/postgresql"
      }
      env {
        POSTGRES_DB       = "immich"
        POSTGRES_USER     = "immich"
        POSTGRES_PASSWORD = "${IMMICH_PG_PASS}"  # injected via op run
      }
    }
  }
}
```

- [ ] Deploy Immich Postgres as Nomad job on port 5433
- [ ] Restore immich database from the dump file produced in the Barman restore step:
  `pg_restore -U immich -h localhost -p 5433 -d immich immich.dump`
- [ ] Verify Immich connects and VectorChord reindexes successfully

### Dragonfly on epyc

- [ ] Deploy as Nomad job (stateless, no data to restore)

### Caddy reverse proxy on epyc

- [ ] Build custom Caddy binary with `caddy-dns/cloudflare` plugin (via `xcaddy` or Docker image `caddy:builder`)
- [ ] Configure Cloudflare API token for DNS challenge (Caddy needs this to get Let's Encrypt certs from a private LAN IP)
- [ ] Write Caddyfile with routes for all apps (see Target State for full example)
- [ ] Assign unique host ports per app (resolve placeholder port conflicts)
- [ ] Deploy as Nomad job or systemd service on epyc
- [ ] Verify HTTPS works for both internal (LAN) and external (tunnel) access

### Cloudflared tunnel on epyc

- [ ] Deploy cloudflared as Nomad job with tunnel credentials from 1Password
- [ ] Catch-all ingress rule pointing to Caddy's HTTPS listener (`service: https://localhost:443`)
- [ ] Set `originServerName: groovie.org` so cloudflared validates Caddy's cert

### Cloudflare DNS records (public apps, managed by Ansible)

- [ ] Define `public_apps` list in `group_vars/all.yml` (auth.groovie.org, paste.ofcode.org)
- [ ] Create `cloudflare-dns` Ansible role (see Target State → DNS strategy for the task)
- [ ] Run playbook to create CNAME records pointing to tunnel
- [ ] Verify public apps resolve externally to Cloudflare

### opnSense host overrides (managed by Ansible)

- [ ] Create API key+secret in opnSense (System → Access → Users) for Ansible
- [ ] Install `ansibleguy.opnsense` collection: `ansible-galaxy collection install ansibleguy.opnsense`
- [ ] Create `opnsense-dns` Ansible role (see Target State → DNS strategy for the task)
- [ ] Run playbook to create all ~22 host overrides
- [ ] Verify LAN clients resolve all app hostnames to 192.168.2.35
- [ ] Verify typos/non-existent names return NXDOMAIN

### Secrets (1Password CLI)

- [ ] Install 1Password CLI (`op`) on all nodes via Ansible
- [ ] Set up a 1Password service account for automated access (non-interactive deploys)
- [ ] Verify `op read` can access the HomeCluster vault from each node

---

## Phase 3: Apps on epyc (compute-heavy)

**Status:** 🔴 Not started

Restore PVC backup data to `/srv/APP/` paths on epyc, then deploy Nomad jobs.

### Data restoration

```bash
rsync -a /mnt/backup/immich/immich-data/ /srv/immich/data/
rsync -a /mnt/backup/vaultwarden/vaultwarden/ /srv/vaultwarden/config/
rsync -a /mnt/backup/freshrss/freshrss/ /srv/freshrss/config/
rsync -a /mnt/backup/linkwarden/linkwarden/ /srv/linkwarden/config/
rsync -a /mnt/backup/thelounge/thelounge/ /srv/thelounge/config/
rsync -a /mnt/backup/unifi/unifi/ /srv/unifi/config/
rsync -a /mnt/backup/duketogo/duketogo-config/ /srv/duketogo/config/
```

### Apps to deploy

- [ ] Immich (server + ML) — host volume: data; connects to Immich Postgres on localhost:5433
- [ ] Authentik (server + worker) — connects to Postgres local + Dragonfly local
- [ ] Vaultwarden — host volume: config; connects to Postgres local
- [ ] Windmill — connects to Postgres local
- [ ] Linkwarden — Postgres local + config volume
- [ ] FreshRSS — Postgres local + config volume
- [ ] Atuin — Postgres local
- [ ] TheLounge — config volume
- [ ] Unifi Controller — config volume
- [ ] DukeTogo — config volume
- [ ] Paste — config volume
- [ ] SMTP Relay — stateless

### Example Nomad job (Immich)

```hcl
job "immich" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "epyc"
  }

  group "immich" {
    network {
      mode = "host"
      port "http" { static = 2283 }
    }

    volume "data" {
      type   = "host"
      source = "immich-data"
    }

    task "server" {
      driver = "docker"

      config {
        image        = "ghcr.io/immich-app/immich-server:release"
        network_mode = "host"
        ports        = ["http"]
      }

      volume_mount {
        volume      = "data"
        destination = "/usr/src/app/upload"
      }

      env {
        DB_HOSTNAME = "127.0.0.1"
        DB_PORT     = "5433"         # Immich's dedicated Postgres container
        DB_DATABASE_NAME = "immich"
        REDIS_HOSTNAME   = "127.0.0.1"
      }

      resources {
        cpu    = 4000
        memory = 8192
      }
    }
  }
}
```

---

## Phase 4: Apps on h4uno (media serving + libraries)

**Status:** 🔴 Not started

### NFS server setup

h4uno exports `/srv/data` to h4dos. This single export contains downloads, video, music,
and books — so hard-links work from downloads into media directories.

```bash
# /etc/exports on h4uno
/srv/data  192.168.2.39(rw,sync,no_subtree_check,no_root_squash)
```

Directory structure on h4uno:
```
/srv/data/              ← NFS export root
├── downloads/          ← SABnzbd writes here (from h4dos via NFS)
├── video/              ← Sonarr/Radarr hard-link from downloads (from h4dos via NFS)
├── music/              ← Lidarr hard-links from downloads (from h4dos via NFS)
└── books/              ← Calibre-Web / Komga (local only)

/srv/plex/config/       ← Plex config (local, not exported)
/srv/ocis/data/         ← OCIS data (local, not exported)
/srv/komga/config/      ← Komga config (local)
/srv/komga/assets/      ← Komga assets (local)
...etc per app
```

### Data restoration

```bash
# Media and downloads into the shared data root
rsync -a /mnt/backup/plex/media-music/ /srv/data/music/
rsync -a /mnt/backup/plex/media-video/ /srv/data/video/
rsync -a /mnt/backup/sabnzbd/sabnzbd-downloads/ /srv/data/downloads/
rsync -a /mnt/backup/calibre-web/media-books/ /srv/data/books/

# App configs (local)
rsync -a /mnt/backup/plex/plex-config/ /srv/plex/config/
rsync -a /mnt/backup/ocis/ocis-data/ /srv/ocis/data/
rsync -a /mnt/backup/komga/komga-config/ /srv/komga/config/
rsync -a /mnt/backup/komga/komga-assets/ /srv/komga/assets/
rsync -a /mnt/backup/calibre-web/calibre-web-config/ /srv/calibre-web/config/
rsync -a /mnt/backup/music-assistant/music-assistant-config/ /srv/music-assistant/config/
```

### Apps to deploy

- [ ] NFS server (via Ansible `nfs` role)
- [ ] Plex — config (local), reads `/srv/data/video/` + `/srv/data/music/` (local NVMe)
- [ ] Komga — config + assets (local)
- [ ] Komf — config (local)
- [ ] Calibre-Web — config (local) + `/srv/data/books/`
- [ ] OCIS — data (local)
- [ ] Music Assistant — config (local) + `/srv/data/music/`
- [ ] Beszel hub — monitoring dashboard (fresh install, no data to restore)
- [ ] Dozzle — Docker log viewer (fresh install, runs on each node as Nomad system job)

---

## Phase 5: Apps on h4dos (download automation)

**Status:** 🔴 Not started

### NFS client setup

h4dos mounts h4uno's `/srv/data` export. All media and downloads appear as one
filesystem, so hard-links work when *arr apps move completed downloads into the
media library (instant, zero copy).

```bash
# /etc/fstab on h4dos
192.168.2.36:/srv/data  /mnt/data  nfs  defaults,_netdev  0 0
```

If h4uno goes down, NFS mounts go stale and *arr apps can't write. This is fine —
Plex is also on h4uno, so there's nothing to serve media to anyway.

### Data restoration

```bash
# App configs only — media/downloads already live on h4uno
rsync -a /mnt/backup/sonarr/sonarr-config/ /srv/sonarr/config/
rsync -a /mnt/backup/radarr/radarr-config/ /srv/radarr/config/
rsync -a /mnt/backup/lidarr/lidarr-config/ /srv/lidarr/config/
rsync -a /mnt/backup/sabnzbd/sabnzbd-config/ /srv/sabnzbd/config/
```

### Apps to deploy

- [ ] NFS client mount (via Ansible `nfs` role)
- [ ] SABnzbd — config (local) + writes to `/mnt/data/downloads/`
- [ ] Sonarr — config (local); `/mnt/data/downloads/` + `/mnt/data/video/`; Postgres on epyc
- [ ] Radarr — config (local); `/mnt/data/downloads/` + `/mnt/data/video/`; Postgres on epyc
- [ ] Lidarr — config (local); `/mnt/data/downloads/` + `/mnt/data/music/`; Postgres on epyc
- [ ] Prowlarr — Postgres on epyc

---

## Phase 6: Frigate on beelink1

**Status:** 🔴 Not started

- [ ] Install Intel GPU drivers + Coral TPU drivers via Ansible
- [ ] Restore Frigate config from backup
- [ ] Deploy Nomad job with device passthrough (USB Coral + `/dev/dri` for GPU)
- [ ] Verify camera feeds and detection

---

## K8s → new setup equivalents

| Kubernetes | New setup |
|------------|-----------|
| Flux GitOps | Nomad job files in git + `nomad job run` via CI or manual |
| HelmRelease | Nomad job spec (HCL) |
| Longhorn (distributed storage) | Local host paths (`/srv/app/`) |
| CNPG operator (shared PG) | PostgreSQL 17 on host (apt install, Ansible-managed) |
| CNPG operator (Immich PG) | Immich's official Postgres Docker image (Nomad job, port 5433) |
| External Secrets + 1Password | 1Password CLI (`op read`) in job templates |
| cert-manager + ingress-nginx | Caddy with built-in ACME + Cloudflare DNS plugin |
| external-dns | Ansible `cloudflare-dns` role (manages CNAME records for public apps) |
| k8s-gateway (internal DNS) | Ansible `opnsense-dns` role (manages Unbound host overrides via API) |
| Cilium CNI | Host networking |
| Consul service discovery | Not needed — static IPs |
| Node affinity | Nomad `constraint` on hostname |
| PVC | Nomad `host_volume` |
| Namespace | Nomad namespace (optional) |
| ConfigMap / Secret | Nomad `template` stanza |
| kube-prometheus-stack | Beszel (metrics/dashboards) + Dozzle (container logs) |
| VolSync restic backups | Nomad periodic jobs or systemd timers running restic |
| Renovate | Renovate watching Nomad job files for Docker image updates (same repo, new file format) |
| Talos (immutable OS) | Ubuntu Server 24.04 LTS managed by Ansible |

---

## Rollback plan

If migration fails at any phase:
1. PVC backups on disk provide all volume data
2. Barman S3 backups provide all Postgres databases
3. GitOps repo still has all k8s manifests
4. Can re-image nodes with Talos and bootstrap Flux to restore

---

## Open questions

None — all resolved. 🎉