# Operations

## Common Commands

All `nomad` commands require two environment variables:

```bash
export NOMAD_ADDR=http://192.168.2.35:4646
export NOMAD_TOKEN=<your-operator-token>  # from 1Password
```

The examples below assume these are set.

### Deploying a Nomad job

```bash
nomad job run jobs/epyc/grafana.nomad.hcl
```

### Running an Ansible playbook

Full site playbook (requires 1Password auth for restic secrets):

```bash
ansible-playbook playbooks/site.yml
```

Target a specific node:

```bash
ansible-playbook playbooks/site.yml -l epyc
```

Target a specific role:

```bash
ansible-playbook playbooks/site.yml -l epyc -t caddy
```

Roles that use `op read` (restic, postgres, cloudflare-dns, opnsense-dns) require 1Password CLI authentication on your local machine. If you only need to run a role like telegraf or base, you can skip authentication by targeting just that tag.

### Checking job status

```bash
nomad job status grafana
```

### Reading job logs

```bash
nomad alloc logs <alloc-id>
# Add -stderr for stderr output
nomad alloc logs -stderr <alloc-id>
```

To find the allocation ID:

```bash
nomad job status grafana | grep running
```

### Setting Nomad variables (secrets)

```bash
nomad var put nomad/jobs/grafana \
  PUSHOVER_USER_KEY=xxx \
  PUSHOVER_APP_KEY=xxx
```

## Updating an App

When Renovate opens a PR with a Docker image update:

1. Review the PR to confirm the update is safe (check release notes for breaking changes)
2. Merge the PR
3. Pull the changes locally: `git pull`
4. Deploy the updated job:
   ```bash
   nomad job run jobs/<node>/<app>.nomad.hcl
   ```
5. Verify the new allocation is healthy:
   ```bash
   nomad job status <app>
   ```

For apps with databases (Sonarr, Radarr, Lidarr, Prowlarr, Authentik, Linkwarden), check whether the upstream release notes mention database migrations. Major version upgrades (e.g., PostgreSQL 17 to 18, or app major version bumps) may require manual steps like `pg_dump`/`pg_restore` or granting schema permissions.

## Updating Host Configuration

When you change an Ansible role or host vars:

1. Run the playbook targeting the affected node and role:
   ```bash
   ansible-playbook playbooks/site.yml -l h4dos -t telegraf
   ```
2. Handlers will restart affected services automatically (e.g., telegraf, caddy).

## PostgreSQL

### Overview

PostgreSQL 17 runs on epyc as a system service (not in a container). It serves as the shared database for most apps. Immich is the exception — it runs its own dedicated PostgreSQL instance as a Nomad job (with the pgvecto.rs extension).

Apps using the shared PostgreSQL: Authentik, Paperless-ngx, Sonarr, Radarr, Lidarr, Prowlarr, Linkwarden.

### Connecting

```bash
ssh ansible@192.168.2.35
sudo -u postgres psql
```

### Common operations

```sql
-- List all databases
\l

-- List all roles
\du

-- Connect to a specific database
\c sonarr

-- Check database sizes
SELECT pg_database.datname, pg_size_pretty(pg_database_size(pg_database.datname))
FROM pg_database ORDER BY pg_database_size(pg_database.datname) DESC;
```

### Creating a database for a new app

```sql
CREATE ROLE myapp LOGIN;
CREATE DATABASE myapp OWNER myapp;
```

If the app needs a separate log database (e.g., Prowlarr):

```sql
CREATE DATABASE "myapp-log" OWNER myapp;
```

### After major app version upgrades

When an app does a major version upgrade, its database migrations may fail with "permission denied for schema public". Fix with:

```sql
GRANT ALL ON SCHEMA public TO <rolename>;
```

This is needed because PostgreSQL 15+ changed the default permissions on the `public` schema.

### Backups (pgBackRest)

pgBackRest handles PostgreSQL backups separately from Restic (which backs up app data in `/srv`).

- **Full backups:** Daily at 2:00 AM (local repo) and 2:30 AM (S3)
- **Differential backups:** Hourly from 3:00–23:00 (local repo only)
- **WAL archiving:** Continuous to both repos
- **Local repo:** `/mnt/backups/pgbackrest`
- **S3 repo:** `homestar-cloudnative-pg` bucket

Check backup status:

```bash
ssh ansible@192.168.2.35
sudo -u postgres pgbackrest --stanza=homestar-pg17 info
```

Run a manual backup:

```bash
ssh ansible@192.168.2.35
sudo -u postgres pgbackrest --stanza=homestar-pg17 --type=full backup
```

Restore (point-in-time):

```bash
# Stop PostgreSQL first
sudo systemctl stop postgresql

# Restore to a specific time
sudo -u postgres pgbackrest --stanza=homestar-pg17 \
  --type=time --target="2026-03-28 12:00:00" restore

# Start PostgreSQL
sudo systemctl start postgresql
```

### Immich database

Immich runs its own dedicated PostgreSQL instance as a container (not the shared system PostgreSQL) because it requires the pgvecto.rs extension. It listens on port **5433** (not the standard 5432).

**Connecting:**

```bash
ssh ansible@192.168.2.35
docker exec -it <immich-postgres-container> psql -U immich immich
```

Or from the host using the client:

```bash
ssh ansible@192.168.2.35
PGPASSWORD=<password> psql -h 127.0.0.1 -p 5433 -U immich immich
```

The password is stored in the Nomad variable `nomad/jobs/immich` under `DB_PASSWORD`.

**Backups:**

The `immich-pg-backup` Nomad job runs as a periodic batch job (daily at 3:00 AM):

1. `pg_dump -Fc` creates a custom-format dump to `/mnt/backups/immich-pg/`
2. Old dumps are pruned, keeping the last 7
3. A poststop task syncs all dumps to S3 (`s3://homestar-cloudnative-pg/immich-pg-dumps/`)

Check recent backup runs:

```bash
nomad job status immich-pg-backup
```

List local backup files:

```bash
ssh ansible@192.168.2.35 ls -lh /mnt/backups/immich-pg/
```

Run a manual backup:

```bash
nomad job periodic force immich-pg-backup
```

**Restoring:**

```bash
# Copy the dump into the host
ssh ansible@192.168.2.35

# Restore using pg_restore against the Immich Postgres on port 5433
PGPASSWORD=<password> pg_restore -h 127.0.0.1 -p 5433 -U immich -d immich --clean /mnt/backups/immich-pg/immich_<timestamp>.dump
```

### Monitoring

Telegraf collects PostgreSQL metrics on epyc for the shared PostgreSQL instance, including connection counts, transaction rates, WAL stats, and replication slot status. These are visible in Grafana. The Immich database is not monitored by Telegraf since it runs as a container on a non-standard port.

---

## Troubleshooting

### Job won't start

1. Check the job status for placement failures:
   ```bash
   nomad job status <app>
   ```
2. Look for constraint errors — the most common cause is the host volume not existing or the node being down.
3. Check allocation events:
   ```bash
   nomad alloc status <alloc-id>
   ```

### Container keeps restarting

1. Check logs for the failing allocation:
   ```bash
   nomad alloc logs -stderr <alloc-id>
   ```
2. Common causes:
   - **Port conflict:** Another app is using the same port. Check with `ss -tlnp` on the host.
   - **Permission denied:** linuxserver images need `PUID`/`PGID` set correctly. Check that `/srv/<app>` is owned by the right UID.
   - **Database connection failed:** Verify PostgreSQL is running and the database/role exists.

### App is unreachable via browser

1. **Check the job is running:** `nomad job status <app>`
2. **Check the port is listening:** SSH to the node and run `ss -tlnp | grep <port>`
3. **Check Caddy routing:** Verify the app has an entry in `caddy_routes` in `host_vars/epyc.yml`
4. **Check DNS:** `dig <app>.groovie.org` should resolve to `192.168.2.35` (Caddy)
5. **Check firewall:** Verify the port is in `base_extra_firewall_ports` for the target node

### Database issues

Connect to PostgreSQL on epyc:

```bash
ssh ansible@192.168.2.35
sudo -u postgres psql
```

Common fixes:

```sql
-- Check if a database exists
\l

-- Check roles
\du

-- Grant schema permissions (needed after major app version upgrades)
GRANT ALL ON SCHEMA public TO <rolename>;

-- Create a missing database
CREATE DATABASE "app-name" OWNER appuser;
```

### Checking metrics and alerts

- **Grafana:** https://grafana.groovie.org
- **VictoriaMetrics query:** `curl 'http://192.168.2.35:8428/api/v1/query?query=up'`
- **Telegraf status on a node:** `ssh ansible@<node> systemctl status telegraf`

### NFS mount issues

If Plex or indexers on h4dos can't see media files:

1. Check the mount: `ssh ansible@192.168.2.39 df -h /mnt/media`
2. If unmounted: `ssh ansible@192.168.2.39 sudo mount -a`
3. Check NFS server on h4uno: `ssh ansible@192.168.2.36 systemctl status nfs-server`

### Restic backup issues

Check last backup time:

```bash
ssh ansible@<node> cat /var/lib/restic-last-backup
```

Run a manual backup:

```bash
ssh ansible@<node> sudo /usr/local/bin/restic-backup.sh
```

Check backup health (requires restic env vars):

```bash
ssh ansible@<node>
sudo -i
source /etc/restic/s3.env
export RESTIC_PASSWORD_FILE=/etc/restic/password
restic -r s3:s3.amazonaws.com/<bucket> snapshots
```
