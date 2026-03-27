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
| epyc | Supermicro 5019D-FTN4 | AMD EPYC 3251 8C/16T @ 2.5-3.1GHz | 4TB NVMe (new) + 2TB SATA SSD | 128GB | No iGPU. Currently runs talos1+talos2 VMs under Proxmox. Will be wiped to bare metal. NVMe: all app data + Postgres. SATA: local backups (`/mnt/backups`). |
| h4uno | ODroid H4 | Intel N97 4C/4T @ 2.0-3.6GHz | 2TB NVMe | 32GB | Quick Sync |
| h4dos | ODroid H4 | Intel N97 4C/4T @ 2.0-3.6GHz | 2TB NVMe | 32GB | Quick Sync (HW transcode for Plex) |
| beelink1 | Beelink Mini S | Intel N5095 4C/4T @ 2.0-2.9GHz | 2TB SATA SSD | 8GB | Coral TPU + Intel GPU for Frigate |

### Databases

**Shared PostgreSQL 16** (CNPG, 3 instances, backs up via Barman to S3):
- authentik, atuin, freshrss, lidarr (main+log), linkwarden, prowlarr, radarr (main+log), sonarr (main+log), vaultwarden, windmill
- **⚠️ Currently down** — was running on talos1 (volume full). Data intact in Barman S3 backups.

**Immich PostgreSQL 16** (separate, pgvecto.rs extension, backs up via Barman to S3):
- immich
- **⚠️ Currently down** — same reason. Data intact in Barman S3 backups.

**Valkey** (Redis-compatible, ephemeral, used by Authentik + Immich)

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
│ Postgres 17  │      │ Komga + Komf     │      │ Plex          │
│ Immich+PG+ML │      │ Calibre-Web      │      │ Sonarr        │
│ Authentik    │      │ Music Assistant  │      │ Radarr        │
│ Valkey       │      │                  │      │ Lidarr        │
│ Linkwarden   │      │                  │      │ SABnzbd       │
│ FreshRSS     │      │                  │      │ Prowlarr      │
│ Atuin        │      │                  │      │               │
│ TheLounge    │      │                  │      │               │
│ Unifi        │      │                  │      │               │
│ Vaultwarden  │      │                  │      │               │
│ OCIS         │      │                  │      │               │
│ DukeTogo     │      │                  │      │               │
│ Paste        │      │                  │      │               │
│ SMTP Relay   │      │                  │      │               │
│ VictoriaM.   │      │                  │      │               │
│ Grafana      │      │                  │      │               │
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

    All nodes also run: Telegraf (metrics collection → VictoriaMetrics on epyc)
```

### Node assignments

Apps are pinned to nodes based on resource needs and data locality.

**epyc** — Heavy compute + all databases (Nomad server + client)
- PostgreSQL 17 (host, via apt) — shared instance for all app databases
- Immich Postgres (Docker, via Nomad) — Immich's official image with VectorChord, port 5433
- Immich — photo library + ML inference (memory/CPU intensive)
- Authentik — SSO (server + worker)
- Valkey — Redis-compatible cache (used by Authentik, Immich)
- Vaultwarden — password vault (Postgres-backed)
- Linkwarden, FreshRSS, Atuin — Postgres-backed, lightweight
- TheLounge, Unifi Controller — small config volumes
- OCIS — ownCloud files
- DukeTogo, Paste, SMTP Relay — minimal/stateless
- VictoriaMetrics — time-series storage (Nomad job)
- Grafana — dashboards (Nomad job)
- Caddy reverse proxy + Cloudflared tunnel

**h4uno** — Music, books + libraries (2TB NVMe, NFS server for music)
- `/srv/data/` — exported via NFS to h4dos, contains:
  - `music/` (550Gi) — Lidarr moves completed downloads here (from h4dos via NFS)
  - `books/` — local only
- Komga + Komf — comic/book library
- Calibre-Web — config + `/srv/data/books/`
- Music Assistant — config + reads `/srv/data/music/`

**h4dos** — Downloads, video + automation (2TB NVMe, Intel N97 Quick Sync for Plex)
- `/srv/downloads/` — local, SABnzbd downloads + par2 processing (I/O intensive)
- `/srv/data/video/` — local, Sonarr/Radarr import directly (no NFS needed)
- `/mnt/media/` — NFS mount of h4uno:/srv/data (for Lidarr music imports)
- Plex — config (local) + reads video from `/srv/data/video/` (local NVMe speed)
- SABnzbd — config (local) + writes to `/srv/downloads/`
- Sonarr — config (local); moves from `/srv/downloads/` → `/srv/data/video/`; Postgres on epyc
- Radarr — config (local); moves from `/srv/downloads/` → `/srv/data/video/`; Postgres on epyc
- Lidarr — config (local); moves from `/srv/downloads/` → `/mnt/media/music/`; Postgres on epyc
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
| h4uno | 192.168.2.36 | — | Music Assistant (mDNS), NFS server |
| h4dos | 192.168.2.39 | — | Plex (advertise URL), downloads + video, NFS client |
| beelink1 | 192.168.2.40 | — | Frigate only |

**Apps requiring host networking** (can't use Docker bridge):

| App | Node | Why | Ports |
|-----|------|-----|-------|
| Unifi Controller | epyc (on .202) | Device adoption requires L2 discovery, STUN, and inform on known IP | 8080, 8443, 3478/UDP, 5514/UDP, 6789, 10001/UDP |
| Music Assistant | h4uno | mDNS/Chromecast discovery requires being on the LAN broadcast domain | 8095 |
| Plex | h4dos | Direct play needs `PLEX_ADVERTISE_URL` pointing to a reachable IP:port | 32400 (can use bridge with mapped port) |
| Frigate | beelink1 | RTSP streams need stable IP:port for cameras to connect to | 5000, 8554, 8555 |

All other apps use Docker bridge networking with Caddy proxying by hostname.

**Plex advertise URL:** `https://192.168.2.39:32400,https://plex.groovie.org:443`

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
  - { zone: groovie.org, name: grafana }
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
- `grafana.groovie.org` — Grafana dashboards

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
  reverse_proxy h4dos:32400
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
grafana.groovie.org {
  reverse_proxy localhost:3001
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

For Nomad jobs, use **Nomad Variables** as the secrets store. Load secrets from
1Password once, then jobs reference them via template — no secrets needed at deploy time:

```bash
# Load a secret into Nomad Variables (repeat when the password changes)
nomad var put nomad/jobs/<job-name> \
  SOME_PASSWORD=$(op read op://HomeCluster/<item>/<field>)

# Deploy normally — no op involvement at run time
nomad job run jobs/epyc/<job-name>.nomad.hcl
```

Reference from the job's template stanza:
```hcl
template {
  data        = <<EOF
{{ with nomadVar "nomad/jobs/<job-name>" -}}
SOME_PASSWORD={{ .SOME_PASSWORD }}
{{- end }}
EOF
  destination = "secrets/app.env"
  env         = true
}
```

Note: `{{ env "VAR" }}` in Nomad templates reads from the Nomad *agent's* environment,
not the submitting shell — it does not work for injecting secrets at deploy time.

For Ansible, `op read` in tasks or a lookup plugin:
```yaml
- name: Set Postgres password
  set_fact:
    pg_password: "{{ lookup('pipe', 'op read op://HomeCluster/cloudnative-pg/POSTGRES_SUPER_PASS') }}"
```

### Backups (new setup)

epyc's 2TB SATA SSD (`/mnt/backups`) serves as the local backup target — physically
separate from the 4TB NVMe holding app data and Postgres. This gives a 3-2-1 pattern:
data on NVMe, backup on SATA, offsite copy on S3.

| What | How | Local (SATA) | Offsite (S3) |
|------|-----|-------------|--------------|
| PostgreSQL 17 (shared) | pgBackRest (WAL archiving + daily base) | `/mnt/backups/pgbackrest/` | S3 (`s3://homestar-cloudnative-pg/pgbackrest/homestar-pg17`) ✅ |
| Immich Postgres (Docker) | pg_dump on schedule (Nomad periodic job) + S3 sync | `/mnt/backups/immich-pg/` | S3 (`s3://homestar-cloudnative-pg/immich-pg-dumps/`) ✅ |
| App config volumes | Restic (systemd timer, daily 3am) | `/mnt/backups/restic/` | S3 (`s3://homestar-cloudnative-pg/restic`) |
| Media (music/video/books) | Restic or rclone | — (too large for SATA) | S3 / second drive |

The SATA drive also provides staging space for the PG16→PG17 Barman restore process
(dump files land at `/mnt/backups/pg-migration/` instead of consuming NVMe space).

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
- [x] Verify Barman backups exist and are recent
- [x] Note S3 credentials from 1Password

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

## Phase 1: epyc — Complete Setup

**Status:** 🟢 Complete

All epyc apps deployed, backups running (pgBackRest, Immich pg_dump, Restic),
monitoring live (Telegraf → VictoriaMetrics → Grafana), tunnel and DNS working.

### Order of operations

1. ✅ Wipe epyc → Ubuntu Server 24.04 LTS bare metal
2. ✅ Run `base` role — networking, SSH, firewall, packages
3. Mount 2TB SATA SSD at `/mnt/backups`
4. Run `docker` role
5. Run `nomad` role → validate Nomad server+client is up
6. Install 1Password CLI + configure service account
7. Restore databases from Barman S3 backups (staging on `/mnt/backups/pg-migration/`)
8. Deploy PostgreSQL 17, restore all databases
9. Deploy Immich Postgres (Nomad job, port 5433), restore Immich database
10. Deploy Valkey
11. Deploy Caddy (all routes) + Cloudflared tunnel
12. Configure DNS: Cloudflare CNAMEs + opnSense Unbound overrides for all apps
13. Restore PVC data to `/srv/` paths on epyc
14. Deploy all epyc apps
15. Configure backups: pgBackRest + Restic

### Ansible roles

Roles that exist in this repo and their status:

- [x] `base` — applied ✅
- [x] `docker` — applied ✅
- [x] `nomad` — applied ✅
- [x] `onepassword` — applied ✅
- [x] `postgres` — applied ✅
- [x] `caddy` — applied ✅
- [x] `cloudflare-dns` — applied ✅
- [x] `opnsense-dns` — applied ✅
- [x] `telegraf` — applied ✅
- [x] `backup` (pgBackRest) — added to `postgres` role; WAL streaming to local + S3, daily full + hourly diff
  - Immich Postgres backed up via `immich-pg-backup` Nomad periodic job (daily pg_dump)
  - [x] Restic for app config volumes — `restic` Ansible role with systemd timers (daily backup, weekly prune)
- [ ] `nfs` — not yet written (needed for Phase 2/3)

### SATA backup drive

Mount the 2TB SATA SSD at `/mnt/backups` before anything else — Barman restore
staging and all local backups land here.

```bash
# Find the SATA device
lsblk

# Format if new
sudo mkfs.ext4 /dev/sdX

# Get UUID for fstab
sudo blkid /dev/sdX

# Mount
sudo mkdir -p /mnt/backups
echo "UUID=<uuid>  /mnt/backups  ext4  defaults  0  2" | sudo tee -a /etc/fstab
sudo mount /mnt/backups
```

### Nomad configuration (epyc)

epyc runs both server and client. The `nomad` role generates this from the template
using `nomad_host_volumes` defined in host_vars.

```hcl
datacenter = "homestar"
data_dir   = "/opt/nomad"

server {
  enabled          = true
  bootstrap_expect = 1  # single server, no quorum
}

client {
  enabled = true
  host_volume "immich-pg-data"    { path = "/srv/immich-pg/data" }
  host_volume "immich-data"       { path = "/srv/immich/data" }
  host_volume "vaultwarden"       { path = "/srv/vaultwarden/config" }
  # ... one host_volume per app data dir on this node
}
```

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

- [ ] Enable Renovate on this repo (same GitHub App as before)
- [ ] Verify Renovate detects image tags in `.hcl` files and creates PRs
- [ ] Merge PRs, then `nomad job run` to apply (manual or via CI)

### Restore databases from Barman S3 backups

Barman backups are physical PG16 data files — they can only restore to PG16. Since
we want PG17, restore to a temporary PG16 instance first, then pg_dump → pg_restore
into PG17.

Dump files and restored data directories land on the SATA backup drive
(`/mnt/backups/pg-migration/`) to avoid consuming NVMe space.

```bash
# Step 1: Create staging area on SATA backup drive
sudo mkdir -p /mnt/backups/pg-migration
sudo chown postgres:postgres /mnt/backups/pg-migration

# Step 2: Export AWS credentials from 1Password (standard AWS S3, no custom endpoint)
export AWS_ACCESS_KEY_ID=$(op read "op://HomeCluster/aws/ACCESS_KEY_ID")
export AWS_SECRET_ACCESS_KEY=$(op read "op://HomeCluster/aws/SECRET_ACCESS_KEY")

# Step 3: Install PG16 temporarily + barman-cli-cloud (PG17 already installed by Ansible)
sudo apt install postgresql-16 barman-cli-cloud

# Step 4: Set up AWS credentials for the postgres user (needed for WAL restore)
sudo mkdir -p ~postgres/.aws
sudo bash -c 'cat > ~postgres/.aws/credentials << EOF
[default]
aws_access_key_id = '"$(op read 'op://HomeCluster/aws/ACCESS_KEY_ID')"'
aws_secret_access_key = '"$(op read 'op://HomeCluster/aws/SECRET_ACCESS_KEY')"'
EOF'
sudo chown -R postgres:postgres ~postgres/.aws
sudo chmod 600 ~postgres/.aws/credentials

# Step 5: Restore shared cluster base backup from S3
sudo mkdir -p /mnt/backups/pg-migration
sudo chown postgres:postgres /mnt/backups/pg-migration
sudo -u postgres barman-cloud-restore \
  --cloud-provider aws-s3 \
  s3://homestar-cloudnative-pg/ \
  postgres16-v5 \
  latest \
  /mnt/backups/pg-migration/restored

# Step 6: Signal that this is a recovery (required — CNPG backups don't include this)
sudo -u postgres touch /mnt/backups/pg-migration/restored/recovery.signal

# Step 7: Create WAL restore wrapper script
# The CNPG restore_command points at /controller/manager which doesn't exist here.
# Override it with barman-cloud-wal-restore to replay all WAL from S3.
sudo -u postgres bash -c 'cat > /tmp/wal-restore.sh << '"'"'EOF'"'"'
#!/bin/bash
exec barman-cloud-wal-restore --cloud-provider aws-s3 s3://homestar-cloudnative-pg/ postgres16-v5 "$1" "$2"
EOF'
sudo chmod +x /tmp/wal-restore.sh

# Step 8: Start PG16, replaying all WAL from S3
# Override several CNPG-specific settings that reference /controller/* paths:
#   ssl=off               — CNPG cert files don't exist here
#   logging_collector=off — CNPG log path doesn't exist here
#   unix_socket_directories=/tmp — CNPG socket path doesn't exist here
#   restore_command       — replace CNPG manager with barman-cloud-wal-restore
# Wait for "database system is ready to accept connections" in the log.
# Archive command errors about /controller/manager after promotion are harmless.
sudo -u postgres /usr/lib/postgresql/16/bin/pg_ctl \
  -D /mnt/backups/pg-migration/restored \
  -l /tmp/pg16-restored.log \
  -o "-p 5434 -c ssl=off -c logging_collector=off -c unix_socket_directories=/tmp \
      -c restore_command='/tmp/wal-restore.sh %f %p'" \
  start

tail -f /tmp/pg16-restored.log
# Wait until: LOG:  database system is ready to accept connections

# Step 9: Dump all shared databases
# Run as postgres so the shell redirect can write to the postgres-owned directory.
# Use -h /tmp because we moved the socket directory there.
sudo -u postgres bash -c '
cd /mnt/backups/pg-migration
for db in authentik atuin freshrss lidarr_main lidarr_log linkwarden \
          prowlarr_main radarr_main radarr_log sonarr_main sonarr_log \
          vaultwarden windmill; do
  echo "Dumping $db..."
  pg_dump -Fc -p 5434 -h /tmp -U postgres $db > ${db}.dump
done'

# Step 10: Repeat for Immich (separate Barman backup, different server name)
sudo -u postgres bash -c 'cat > /tmp/wal-restore-immich.sh << '"'"'EOF'"'"'
#!/bin/bash
exec barman-cloud-wal-restore --cloud-provider aws-s3 s3://homestar-cloudnative-pg/ immich-postgres16-v1 "$1" "$2"
EOF'
sudo chmod +x /tmp/wal-restore-immich.sh

sudo -u postgres barman-cloud-restore \
  --cloud-provider aws-s3 \
  s3://homestar-cloudnative-pg/ \
  immich-postgres16-v1 \
  latest \
  /mnt/backups/pg-migration/restored-immich

sudo -u postgres touch /mnt/backups/pg-migration/restored-immich/recovery.signal

sudo -u postgres /usr/lib/postgresql/16/bin/pg_ctl \
  -D /mnt/backups/pg-migration/restored-immich \
  -l /tmp/pg16-restored-immich.log \
  -o "-p 5435 -c ssl=off -c logging_collector=off -c unix_socket_directories=/tmp \
      -c restore_command='/tmp/wal-restore-immich.sh %f %p' \
      -c shared_preload_libraries=''" \
  start
# shared_preload_libraries='' is required — the Immich CNPG image had VectorChord
# in shared_preload_libraries but the standard Ubuntu PG16 package doesn't have it.
# pg_dump still works correctly without it; VectorChord is only needed at query time.

tail -f /tmp/pg16-restored-immich.log
# Wait until: LOG:  database system is ready to accept connections

sudo -u postgres bash -c 'pg_dump -Fc -p 5435 -h /tmp -U postgres immich > /mnt/backups/pg-migration/immich.dump'

# Step 11: Verify all dumps are valid
for f in /mnt/backups/pg-migration/*.dump; do pg_restore --list $f > /dev/null && echo "$f OK"; done

# Step 12: Stop both temporary PG16 instances and clean up
sudo -u postgres /usr/lib/postgresql/16/bin/pg_ctl -D /mnt/backups/pg-migration/restored stop
sudo -u postgres /usr/lib/postgresql/16/bin/pg_ctl -D /mnt/backups/pg-migration/restored-immich stop
sudo apt remove postgresql-16
rm -rf /mnt/backups/pg-migration/restored /mnt/backups/pg-migration/restored-immich
```

- [x] Restore shared Barman backup (`postgres16-v5`)
- [x] Restore Immich Barman backup (`immich-postgres16-v1`)
- [x] Dump all databases from temporary PG16
- [x] Verify all dump files
- [x] Remove temporary PG16

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

Databases to restore (from dump files produced in the Barman restore step above).
App roles must be created first — `CREATE POLICY` statements in the schema reference
them and will fail if the roles don't exist. Roles get proper passwords when each app
is deployed; these are just placeholders to satisfy the restore.

```bash
# Create placeholder app roles
sudo -u postgres bash -c '
for role in authentik atuin freshrss lidarr linkwarden prowlarr radarr \
            sonarr vaultwarden windmill windmill_user windmill_admin; do
  psql -c "CREATE ROLE $role LOGIN;" 2>/dev/null || echo "$role already exists"
done'

# Restore all databases
sudo -u postgres bash -c '
cd /mnt/backups/pg-migration
for db in authentik atuin freshrss lidarr_main lidarr_log linkwarden \
          prowlarr_main radarr_main radarr_log sonarr_main sonarr_log \
          vaultwarden windmill; do
  echo "Restoring $db..."
  createdb -U postgres $db
  pg_restore --no-owner --no-privileges -U postgres -d $db ${db}.dump
done'
```

- [x] authentik
- [x] atuin
- [x] freshrss
- [x] lidarr_main, lidarr_log
- [x] linkwarden
- [x] prowlarr_main
- [x] radarr_main, radarr_log
- [x] sonarr_main, sonarr_log
- [x] vaultwarden
- [x] windmill

Note: placeholder roles were created for all apps to satisfy schema restore (see above).
App-specific passwords and connection verification happen when deploying each app in
the Apps section below.

### Immich PostgreSQL on epyc (separate, Dockerized via Nomad)

Immich gets its own Postgres container using Immich's official image. Rationale:
- Immich upgrades frequently and each release can change which VectorChord version
  is required, run heavy reindexing, or need Postgres config changes.
- Running against their tested image means upgrades follow their docs exactly.
- If an Immich upgrade goes sideways, only the Immich database is affected — the
  shared Postgres with 12 other databases is untouched.
- On a 128GB machine, a second Postgres instance is negligible overhead.

The job spec lives at `jobs/epyc/immich-postgres.nomad.hcl`. Key lessons from deployment:

- **Secrets via Nomad Variables** — not `op run`. Store once, reference from template.
  The `{{ env }}` template function reads from the Nomad agent's environment, not the
  submitting shell, so it doesn't work for injecting secrets at deploy time.
- **`PGPORT = "5433"`** — required. With host networking, `port { static = 5433 }` only
  reserves and advertises the port; the container still defaults to 5432 internally.
  Setting `PGPORT` is what actually makes postgres listen on 5433.
- **Host directory ownership** — `/srv/immich-pg/data` must be owned by uid 999
  (the postgres user inside the container), not root.

```bash
# One-time: create data directory with correct ownership
ssh epyc "sudo mkdir -p /srv/immich-pg/data && sudo chown 999:999 /srv/immich-pg/data"

# One-time: load secret into Nomad Variables (refresh when password changes)
nomad var put nomad/jobs/immich-postgres \
  POSTGRES_PASSWORD=$(op read op://HomeCluster/immich/POSTGRES_PASS)

# Re-apply nomad role to register the host volume, then deploy
ansible-playbook playbooks/site.yml --limit epyc --tags nomad
nomad job run jobs/epyc/immich-postgres.nomad.hcl
```

- [x] Deploy Immich Postgres as Nomad job on port 5433
- [x] Restore immich database (see procedure below)
- [x] Verify Immich connects and VectorChord reindexes successfully

#### Immich database restore procedure

The old k8s cluster used **pgvecto.rs** (`vectors` extension). The new Immich image uses
**pgvector** (`vector`) and **VectorChord** (`vchord`) instead. A straight `pg_restore`
doesn't work — the dump references `vectors.vector` types and pgvecto.rs HNSW indexes.
Additional complications: `pg_restore -f | psql` over TCP triggers psql's backslash
restriction (blocking COPY data), and the dump's SQL preamble resets `search_path` to
empty (hiding the `vector` type from extensions). Solution: split the restore into three
sections and handle each separately.

```bash
# Step 1: Build a filtered restore list (exclude the vectors extension)
pg_restore --list /mnt/backups/pg-migration/immich.dump > /tmp/immich-restore.list
grep -v 'EXTENSION - vectors\|EXTENSION vectors' /tmp/immich-restore.list > /tmp/immich-restore-filtered.list

# Step 2: Generate pre-data and post-data SQL files
pg_restore \
  --use-list=/tmp/immich-restore-filtered.list \
  --section=pre-data \
  -f /tmp/immich-pre-data.sql \
  /mnt/backups/pg-migration/immich.dump

pg_restore \
  --use-list=/tmp/immich-restore-filtered.list \
  --section=post-data \
  -f /tmp/immich-post-data.sql \
  /mnt/backups/pg-migration/immich.dump

# Step 3: Fix vectors.vector type references in both SQL files
sed -i 's/vectors\.vector/vector/g' /tmp/immich-pre-data.sql /tmp/immich-post-data.sql

# Step 4: Fix the psql backslash restriction and empty search_path in both SQL files
# The dump includes \restrict <token> which re-enables psql's TCP security restriction
# and resets search_path to '' which hides the vector type from extensions.
sed -i 's/^\\restrict .*/\\unrestrict/' /tmp/immich-pre-data.sql /tmp/immich-post-data.sql
sed -i "s/set_config('search_path', '', false)/set_config('search_path', 'public', false)/" \
  /tmp/immich-pre-data.sql /tmp/immich-post-data.sql

# Step 5: Fix the HNSW index syntax (pgvecto.rs uses USING vectors; pgvector uses USING hnsw)
python3 << 'EOF'
with open('/tmp/immich-post-data.sql', 'r') as f:
    content = f.read()

old_clip = """CREATE INDEX clip_index ON public.smart_search USING vectors (embedding vector_cos_ops) WITH (options='[indexing.hnsw]
m = 16
ef_construction = 300');"""

old_face = """CREATE INDEX face_index ON public.face_search USING vectors (embedding vector_cos_ops) WITH (options='[indexing.hnsw]
m = 16
ef_construction = 300');"""

content = content.replace(old_clip, "CREATE INDEX clip_index ON public.smart_search USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 300);")
content = content.replace(old_face, "CREATE INDEX face_index ON public.face_search USING hnsw (embedding vector_cosine_ops) WITH (m = 16, ef_construction = 300);")

with open('/tmp/immich-post-data.sql', 'w') as f:
    f.write(content)
EOF

# Step 6: Create fresh database
psql -h 127.0.0.1 -p 5433 -U immich -d postgres -c "DROP DATABASE IF EXISTS immich;"
psql -h 127.0.0.1 -p 5433 -U immich -d postgres -c "CREATE DATABASE immich OWNER immich;"

# Step 7: Create extensions (must exist before schema is applied)
psql -h 127.0.0.1 -p 5433 -U immich -d immich -c "
  CREATE EXTENSION IF NOT EXISTS vector;
  CREATE EXTENSION IF NOT EXISTS vchord;
"

# Step 8: Apply schema
psql -h 127.0.0.1 -p 5433 -U immich -d immich -f /tmp/immich-pre-data.sql

# Step 9: Load data — pg_restore handles COPY directly, no psql backslash issues
pg_restore \
  -h 127.0.0.1 -p 5433 \
  -U immich \
  --no-owner --no-privileges \
  -d immich \
  --section=data \
  --use-list=/tmp/immich-restore-filtered.list \
  /mnt/backups/pg-migration/immich.dump

# Step 10: Apply indexes and constraints
psql -h 127.0.0.1 -p 5433 -U immich -d immich -f /tmp/immich-post-data.sql

# Verify: check table sizes
psql -h 127.0.0.1 -p 5433 -U immich -d immich -c "
  SELECT tablename, pg_size_pretty(pg_total_relation_size('public.'||tablename))
  FROM pg_tables WHERE schemaname = 'public'
  ORDER BY pg_total_relation_size('public.'||tablename) DESC LIMIT 10;
"
```

Expected errors (harmless):
- `\unrestrict: missing required argument` — version difference, schema still applied
- `\unrestrict: not currently in restricted mode` — stray token at end of file
- `relation "vectors.pg_vector_index_stat" does not exist` — pgvecto.rs system table GRANT, irrelevant

### Valkey on epyc

Valkey is stateless — no data to restore. Listens on port 6379 with host networking.
Authentik and Immich both connect to `127.0.0.1:6379`.

```bash
nomad job run jobs/epyc/valkey.nomad.hcl
```

- [x] Deploy as Nomad job (stateless, no data to restore)

### Caddy reverse proxy on epyc

Deployed as a systemd service via the `caddy` Ansible role. Binary downloaded from the
Caddy download API with the `caddy-dns/cloudflare` plugin (v0.2.4) baked in. Cloudflare
API token stored in 1Password and written to `/etc/caddy/env` by the role. Routes are
managed via `caddy_routes` in `host_vars/epyc.yml` — add a route and re-run
`--tags caddy` to deploy; Caddy reloads without dropping connections.

```bash
ansible-playbook playbooks/site.yml --limit epyc --tags caddy
```

- [x] Build custom Caddy binary with `caddy-dns/cloudflare` plugin
- [x] Configure Cloudflare API token for DNS challenge
- [x] Deploy as systemd service on epyc
- [x] Verify HTTPS works for both internal (LAN) and external (tunnel) access
- [ ] Routes to h4uno/h4dos/beelink1 will 502 until those nodes are up — expected

### Cloudflared tunnel on epyc

A **new** tunnel (`e30c91ae-29eb-4b4b-9a9c-c41df2dc7b90`) was created for epyc,
separate from the existing k8s tunnel (`external.groovie.org`). This allows gradual
migration — as each app is deployed on epyc, its CNAME is updated from the old tunnel
to `e30c91ae-29eb-4b4b-9a9c-c41df2dc7b90.cfargotunnel.com`. The old k8s tunnel stays
active until all apps are migrated.

Deployed as a locally-managed Nomad job with a catch-all ingress to Caddy. Cloudflared
preserves the original hostname from the Cloudflare edge, so Caddy receives the correct
`Host` header and serves the matching TLS cert automatically.

```bash
# One-time: create tunnel (run from workstation with cloudflared installed)
cloudflared tunnel login
cloudflared tunnel create epyc

# One-time: store credentials in Nomad Variables
nomad var put nomad/jobs/cloudflared \
  TUNNEL_CREDENTIALS="$(cat ~/.cloudflared/e30c91ae-29eb-4b4b-9a9c-c41df2dc7b90.json)"

# Deploy
nomad job run jobs/epyc/cloudflared.nomad.hcl
```

- [x] Create new tunnel for epyc
- [x] Store tunnel credentials in Nomad Variables
- [x] Deploy cloudflared as Nomad job with catch-all ingress to Caddy
- [x] Verify external access works via cloudflared tunnel

### DNS (do now, not later)

Configure all DNS up front. LAN-only app hostnames will resolve to epyc's Caddy even
before those apps' nodes are up — Caddy returns 502 until the backend exists, which
is better than NXDOMAIN.

**Cloudflare CNAME records (public apps):**

Public app CNAMEs are updated per-app as they're deployed on epyc. Each CNAME switches
from the old k8s tunnel (`external.groovie.org`) to the new epyc tunnel
(`e30c91ae-29eb-4b4b-9a9c-c41df2dc7b90.cfargotunnel.com`).

- [x] Create `cloudflare-dns` Ansible role
- [x] Run playbook to create CNAME records for public apps pointing to new tunnel
- [x] Verify public apps resolve externally to Cloudflare

**opnSense host overrides (all apps):**
- [x] Create API key+secret in opnSense, stored in 1Password
- [x] Install `ansibleguy.opnsense` collection
- [x] Create `opnsense-dns` Ansible role
- [x] Run playbook to create all ~22 host overrides pointing to 192.168.2.35
- [x] Verify LAN clients resolve all app hostnames to 192.168.2.35

```bash
ansible-playbook playbooks/site.yml --tags cloudflare-dns
ansible-playbook playbooks/site.yml --tags opnsense-dns
```

### Secrets (1Password CLI)

- [x] Install 1Password CLI (`op`) on epyc via Ansible
- [x] Set up a 1Password service account with token exported via `/etc/profile.d/1password.sh`
- [x] Verify `op read` can access the HomeCluster vault from epyc

### Data restoration (epyc apps) ✅ Complete

Backup data was on the workstation at `/run/media/ben/Archive/ClusterBackup/`. Rsynced
to epyc over SSH with `sudo rsync` to preserve ownership:

```bash
SRC=/run/media/ben/Archive/ClusterBackup

ssh epyc "sudo mkdir -p /srv/immich/data /srv/vaultwarden/config /srv/freshrss/config \
  /srv/linkwarden/config /srv/thelounge/config /srv/unifi/config /srv/duketogo/config \
  /srv/paste/config"

rsync -avP --rsync-path="sudo rsync" $SRC/immich/immich-data/ epyc:/srv/immich/data/
rsync -avP --rsync-path="sudo rsync" $SRC/vaultwarden/vaultwarden/ epyc:/srv/vaultwarden/config/
rsync -avP --rsync-path="sudo rsync" $SRC/freshrss/freshrss/ epyc:/srv/freshrss/config/
rsync -avP --rsync-path="sudo rsync" $SRC/linkwarden/linkwarden/ epyc:/srv/linkwarden/config/
rsync -avP --rsync-path="sudo rsync" $SRC/thelounge/thelounge/ epyc:/srv/thelounge/config/
rsync -avP --rsync-path="sudo rsync" $SRC/unifi/unifi/ epyc:/srv/unifi/config/
rsync -avP --rsync-path="sudo rsync" $SRC/duketogo/duketogo-config/ epyc:/srv/duketogo/config/
rsync -avP --rsync-path="sudo rsync" $SRC/paste/paste/ epyc:/srv/paste/config/
```

### Apps to deploy on epyc

- [x] Immich (server + ML v2.6.2 + Postgres 17) — consolidated into single Nomad job with Postgres as prestart sidecar
- [x] Authentik (server + worker) — connects to Postgres local + Valkey local
  - Custom theme assets (logo, background, CSS) stored in `jobs/epyc/authentik-assets/`
    and must be synced to `/srv/authentik/assets/` on epyc before deploying:
    `rsync -avP --rsync-path="sudo rsync" jobs/epyc/authentik-assets/ epyc:/srv/authentik/assets/`
  - DB role needs password + ownership: `ALTER ROLE authentik WITH PASSWORD '...'; ALTER DATABASE authentik OWNER TO authentik;`
  - Grant table access: `GRANT ALL ON ALL TABLES/SEQUENCES/FUNCTIONS IN SCHEMA public TO authentik;`
- [x] Vaultwarden — host volume: config; connects to Postgres local (port 8081)
  - DB creds from 1Password `vaultwarden` item; admin token must be Argon2id hashed
  - DB needs schema grant: `GRANT ALL ON SCHEMA public TO vaultwarden;`
  - SMTP via smtp-relay.groovie.org:25
- [ ] ~~Windmill — skipped, not in use~~
- [x] Linkwarden — Postgres local + config volume (port 3000, v2.14.0)
  - Authentik SSO + OpenAI auto-tagging enabled
  - Run `npx playwright install chromium` in container for link preservation
  - DB needs ownership: `REASSIGN OWNED` + schema grant
- [x] FreshRSS — Postgres local + config volume (port 8082)
  - OIDC secrets from 1Password `freshrss` item, DB creds from `freshrss` item
  - Restored config had old k8s DB host — updated to `127.0.0.1` in `/srv/freshrss/config/config.php`
  - DB user password and table grants needed: `ALTER USER freshrss WITH PASSWORD '...'; GRANT ALL ON ALL TABLES/SEQUENCES IN SCHEMA public TO freshrss;`
- [x] Atuin — Postgres local (port 8888)
  - DB needs table ownership reassigned to atuin user
- [x] TheLounge — config volume (port 9090)
  - Restored config had port 9000 hardcoded — updated to 9090 in config.js
- [x] Unifi Controller — config volume (jacobalberty/unifi:v10.0.162)
  - Restored from backup via setup wizard at `https://<ip>:8443` directly (not through Caddy — restore upload fails via reverse proxy)
  - Caddy reverse proxy requires `header_up Host {hostport}` for HTTPS backends (Caddy 2.11+ changed default behavior)
  - UFW ports needed: 8443/tcp, 8080/tcp, 3478/udp, 10001/udp, 5514/udp, 6789/tcp, 8843/tcp, 8880/tcp
  - Added `base_extra_firewall_ports` to base role for per-host UFW rules
- [x] DukeTogo — config volume, GCR private image (needs gcloud CLI on epyc for auth)
  - Secrets from 1Password `duketogo` item (discord token, sentry DSN, stonks API key)
  - Required adding gcloud CLI installation to docker Ansible role (`docker_install_gcloud: true`)
  - Image rebuilt via Cloud Build after old GCR tag was removed
- [x] Paste — stateless, uses existing Valkey on localhost:6379 (port 6543)
- [x] SMTP Relay — stateless (Maddy on port 25)
  - Secrets from 1Password `smtp-relay` item (hostname, server, username, password)
  - Used by Authentik and Vaultwarden via smtp-relay.groovie.org
  - Added opnSense DNS override for smtp-relay.groovie.org
- [ ] ~~Beszel agent — replaced by Telegraf + VictoriaMetrics + Grafana~~
- [ ] ~~Dozzle — dropped; Nomad UI provides sufficient log access~~
- [x] Telegraf — host-installed via Ansible role (collects system, Docker, Nomad, Postgres metrics)
  - Uses InfluxDB line protocol output to VictoriaMetrics
  - Collects: CPU, memory, disk, diskio, net, system, processes, Docker, PostgreSQL, Nomad
- [x] VictoriaMetrics — Nomad job on epyc (port 8428, 12-month retention)
  - Receives metrics from Telegraf via InfluxDB write endpoint
- [x] Grafana — Nomad job on epyc (port 3001, VictoriaMetrics as Prometheus datasource)

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
        DB_HOSTNAME      = "127.0.0.1"
        DB_PORT          = "5433"
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

### Networking setup

- [x] epyc primary IP: 192.168.2.35 — configured via `base` role ✅
- [x] epyc secondary IP: 192.168.2.202 — configured via `base` role ✅
- [x] opnSense: create API key for Ansible, reserve all IPs in DHCP
- [x] opnSense DNS: run `opnsense-dns` playbook
- [x] Cloudflare DNS: run `cloudflare-dns` playbook
- [x] Cloudflared tunnel on epyc with catch-all to Caddy (via HTTP listener on :8780)
- [x] Unifi devices already inform to 192.168.2.202 — no re-adoption needed

---

## Phase 2: beelink1 — Frigate

**Status:** ✅ Complete

Simplest node — just Frigate with hardware passthrough. Re-imaged with Ubuntu
24.04, bootstrapped, all roles applied, Frigate deployed and running.

### Ansible roles for beelink1

- [x] `base`
- [x] `docker`
- [x] `nomad` (client only — connects to epyc:4647)
- [x] `onepassword`
- [x] `telegraf` (metrics collection → VictoriaMetrics on epyc)
- [x] `restic` (S3-only backup of `/srv/frigate/config`)

### Apps deployed

- [x] Frigate 0.17.1 — Docker with privileged mode, USB Coral TPU + Intel GPU (`/dev/dri`) passthrough
- [x] Secrets via Nomad Variables from 1Password
- [x] Caddy route on epyc (`frigate.groovie.org` → `192.168.2.40:5000`)
- [x] Firewall ports open (5000/tcp, 8554/tcp, 8555/tcp+udp)

---

## Phase 3: h4uno — Media Serving + Libraries

**Status:** 🔴 Not started

After re-imaging: run `base`, `docker`, `nomad`, `onepassword`,
`nfs` (server), `telegraf`, and `backup` roles, then restore data and deploy jobs.

### NFS server setup

h4uno exports `/srv/data` to h4dos for music library access (Lidarr imports).

```bash
# /etc/exports on h4uno
/srv/data  192.168.2.39(rw,sync,no_subtree_check,no_root_squash)
```

Directory structure on h4uno:
```
/srv/data/              ← NFS export root
├── music/              ← Lidarr moves completed downloads here (from h4dos via NFS)
└── books/              ← Calibre-Web / Komga (local only)

/srv/komga/config/      ← Komga config (local)
/srv/komga/assets/      ← Komga assets (local)
/srv/calibre-web/config/ ← Calibre-Web config (local)
/srv/music-assistant/config/ ← Music Assistant config (local)
```

### Ansible roles for h4uno

- [ ] `base`
- [ ] `docker`
- [ ] `nomad` (client only — connects to epyc:4647)
- [ ] `onepassword`
- [ ] `nfs` (server — exports `/srv/data`)
- [ ] `telegraf` (metrics collection → VictoriaMetrics on epyc)
- [ ] `restic` (backup app configs)

### Data restoration

```bash
# Media
rsync -a /mnt/backup/plex/media-music/ /srv/data/music/
rsync -a /mnt/backup/calibre-web/media-books/ /srv/data/books/

# App configs
rsync -a /mnt/backup/komga/komga-config/ /srv/komga/config/
rsync -a /mnt/backup/komga/komga-assets/ /srv/komga/assets/
rsync -a /mnt/backup/calibre-web/calibre-web-config/ /srv/calibre-web/config/
rsync -a /mnt/backup/music-assistant/music-assistant-config/ /srv/music-assistant/config/
```

### Apps to deploy

- [ ] NFS server (via Ansible `nfs` role)
- [ ] Komga — config + assets (local)
- [ ] Komf — config (local)
- [ ] Calibre-Web — config (local) + `/srv/data/books/`
- [ ] Music Assistant — config (local) + `/srv/data/music/`

---

## Phase 4: h4dos — Downloads, Video + Automation

**Status:** 🔴 Not started

After re-imaging: run `base`, `docker`, `nomad`, `onepassword`, `nfs` (client),
`telegraf`, and `restic` roles, then restore data and deploy jobs.

### Storage layout

Downloads and video stay local on h4dos. Plex reads video locally for NVMe
speed. Lidarr imports music to h4uno via NFS.

```
/srv/downloads/         ← SABnzbd downloads + processing (local, I/O intensive)
/srv/data/video/        ← Sonarr/Radarr import destination (local)
/srv/plex/config/       ← Plex config (local)
/mnt/media/             ← NFS mount of h4uno:/srv/data (for Lidarr music imports)
└── music/              ← Lidarr import destination
```

```bash
# /etc/fstab on h4dos
192.168.2.36:/srv/data  /mnt/media  nfs  defaults,_netdev  0 0
```

If h4uno goes down, Lidarr can't import music. SABnzbd, Sonarr, Radarr, and
Plex all work locally and are unaffected.

### Ansible roles for h4dos

- [ ] `base`
- [ ] `docker`
- [ ] `nomad` (client only — connects to epyc:4647)
- [ ] `onepassword`
- [ ] `nfs` (client — mounts h4uno:/srv/data at /mnt/media)
- [ ] `telegraf` (metrics collection → VictoriaMetrics on epyc)
- [ ] `restic` (backup app configs)

### Data restoration

```bash
# Video + downloads
rsync -a /mnt/backup/plex/media-video/ /srv/data/video/
rsync -a /mnt/backup/sabnzbd/sabnzbd-downloads/ /srv/downloads/

# App configs
rsync -a /mnt/backup/plex/plex-config/ /srv/plex/config/
rsync -a /mnt/backup/sonarr/sonarr-config/ /srv/sonarr/config/
rsync -a /mnt/backup/radarr/radarr-config/ /srv/radarr/config/
rsync -a /mnt/backup/lidarr/lidarr-config/ /srv/lidarr/config/
rsync -a /mnt/backup/sabnzbd/sabnzbd-config/ /srv/sabnzbd/config/
```

### Apps to deploy

- [ ] NFS client mount (via Ansible `nfs` role)
- [ ] Plex — config (local) + reads `/srv/data/video/` (local NVMe)
- [ ] SABnzbd — config (local) + writes to `/srv/downloads/`
- [ ] Sonarr — config (local); `/srv/downloads/` + `/srv/data/video/`; Postgres on epyc
- [ ] Radarr — config (local); `/srv/downloads/` + `/srv/data/video/`; Postgres on epyc
- [ ] Lidarr — config (local); `/srv/downloads/` + `/mnt/media/music/`; Postgres on epyc
- [ ] Prowlarr — Postgres on epyc

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
| kube-prometheus-stack | Telegraf (collection) + VictoriaMetrics (storage) + Grafana (dashboards) |
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