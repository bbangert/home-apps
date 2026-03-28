# Adding an App

This guide walks through deploying a new application to the cluster. The example adds a hypothetical app called "myapp" to epyc.

> **Prerequisites:** All `nomad` commands require `NOMAD_ADDR` and `NOMAD_TOKEN` to be set. See [Operations](operations.md#common-commands).

## 1. Choose a node

Decide which node will run the app based on its resource needs and any hardware requirements (GPU, NFS access, etc.). See the [architecture doc](architecture.md) for node roles.

## 2. Create the host volume

Add the volume to `inventories/production/host_vars/<node>.yml`:

```yaml
nomad_host_volumes:
  # ... existing volumes ...
  - name: myapp-config
    path: /srv/myapp/config
```

Run the Nomad role to register the volume:

```bash
ansible-playbook playbooks/site.yml -l epyc -t nomad
```

Create the directory on the host (Nomad declares volumes but doesn't create the directories):

```bash
ssh ansible@192.168.2.35 sudo mkdir -p /srv/myapp/config
```

If the app uses a specific UID (common with linuxserver images, default PUID/PGID is 1000), set ownership:

```bash
ssh ansible@192.168.2.35 sudo chown 1000:1000 /srv/myapp/config
```

## 3. Create the Nomad job

Create `jobs/<node>/myapp.nomad.hcl`:

```hcl
job "myapp" {
  datacenters = ["homestar"]
  type        = "service"

  constraint {
    attribute = "${attr.unique.hostname}"
    value     = "epyc"
  }

  group "myapp" {
    network {
      mode = "host"
      port "http" { static = 8090 }
    }

    volume "config" {
      type      = "host"
      source    = "myapp-config"
      read_only = false
    }

    restart {
      attempts = 3
      interval = "5m"
      delay    = "15s"
      mode     = "fail"
    }

    task "myapp" {
      driver = "docker"

      config {
        image        = "lscr.io/linuxserver/myapp:1.0.0"
        network_mode = "host"
        ports        = ["http"]
      }

      volume_mount {
        volume      = "config"
        destination = "/config"
      }

      env {
        PUID = "1000"
        PGID = "1000"
        TZ   = "America/Los_Angeles"
      }

      resources {
        cpu    = 500
        memory = 512
      }
    }
  }
}
```

Key decisions:
- **Image:** Always pin to a specific version tag, never `:latest`. Prefer linuxserver images when available.
- **Port:** Choose a port that doesn't conflict with existing apps. Check `host_vars/<node>.yml` for ports in use.
- **Resources:** Start conservative; adjust after observing actual usage in Grafana.

## 4. Open the firewall port

If the app runs on a node other than epyc (where Caddy proxies via localhost), add the port to `base_extra_firewall_ports` in the node's host_vars:

```yaml
base_extra_firewall_ports:
  # ... existing ports ...
  - { port: "8090", proto: tcp }
```

Apply:

```bash
ansible-playbook playbooks/site.yml -l <node> -t base
```

Apps on epyc that are only accessed through Caddy on localhost don't need a firewall rule.

## 5. Add a Caddy route

Add the route to `caddy_routes` in `host_vars/epyc.yml`:

```yaml
caddy_routes:
  # ... existing routes ...
  - hostname: myapp.groovie.org
    backend: localhost:8090       # or 192.168.2.x:8090 for remote nodes
```

Apply:

```bash
ansible-playbook playbooks/site.yml -l epyc -t caddy
```

## 6. Add DNS

Add the app to `all_apps` in `group_vars/all.yml`:

```yaml
all_apps:
  # ... existing apps ...
  - zone: groovie.org
    name: myapp
```

If the app should be publicly accessible, also add it to `public_apps`.

Apply DNS:

```bash
# Internal DNS (opnSense)
ansible-playbook playbooks/site.yml -t opnsense-dns

# External DNS (Cloudflare) — only if in public_apps
ansible-playbook playbooks/site.yml -t cloudflare-dns
```

## 7. Set up a database (if needed)

If the app needs PostgreSQL, add the database to the `postgres` role's configuration in `host_vars/epyc.yml` or the role's defaults, then run:

```bash
ansible-playbook playbooks/site.yml -l epyc -t postgres
```

Or create it manually:

```bash
ssh ansible@192.168.2.35
sudo -u postgres psql -c "CREATE ROLE myapp LOGIN;"
sudo -u postgres psql -c "CREATE DATABASE myapp OWNER myapp;"
```

Then add the database connection details to the Nomad job's environment variables or use a Nomad variable for the password.

## 8. Add secrets (if needed)

If the app needs secrets at runtime, first store them in 1Password under the HomeCluster vault, then set them as Nomad variables using `op read` **before deploying**:

```bash
nomad var put nomad/jobs/myapp \
  SECRET_KEY="$(op read 'op://HomeCluster/myapp/SECRET_KEY')" \
  API_TOKEN="$(op read 'op://HomeCluster/myapp/API_TOKEN')"
```

Reference them in the job file with a template block:

```hcl
template {
  data        = <<EOF
{{ with nomadVar "nomad/jobs/myapp" -}}
SECRET_KEY={{ .SECRET_KEY }}
API_TOKEN={{ .API_TOKEN }}
{{- end }}
EOF
  destination = "secrets/app.env"
  env         = true
}
```

## 9. Deploy

```bash
nomad job run jobs/epyc/myapp.nomad.hcl
```

Verify it's running:

```bash
nomad job status myapp
```

Check the app is reachable at `https://myapp.groovie.org`.

## 10. Add to backups

If the app stores data you care about, it's already covered — restic backs up `/srv` on all nodes by default. Check `host_vars/<node>.yml` to make sure the app's data path isn't in `restic_exclude_patterns`.

## 11. Monitoring

Basic monitoring is automatic — Telegraf already collects Docker container metrics (CPU, memory, network) on every node, and the existing container memory alert will fire if the app exceeds 90% of its memory limit.

### Adding an alert rule

If the app needs a specific alert (e.g., a health endpoint check), add a rule to the alert provisioning template in `jobs/epyc/grafana.nomad.hcl`. Alert rules are defined in the `# Provision alert rules` template block under `groups[0].rules`. Follow the pattern of existing rules:

```yaml
      - uid: myapp-health
        title: MyApp unhealthy
        condition: C
        data:
          - refId: A
            relativeTimeRange:
              from: 300
              to: 0
            datasourceUid: victoriametrics
            model:
              expr: <promql expression>
              instant: true
          - refId: C
            relativeTimeRange:
              from: 0
              to: 0
            datasourceUid: __expr__
            model:
              type: threshold
              expression: A
              conditions:
                - evaluator:
                    type: gt
                    params: [<threshold>]
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: MyApp is unhealthy
```

After editing, redeploy Grafana:

```bash
nomad job run jobs/epyc/grafana.nomad.hcl
```

### Adding a dashboard

Grafana dashboards are stored as JSON files in `/srv/grafana/dashboards` on epyc (mounted as a host volume). The dashboard provider is configured to auto-load JSON files from that directory.

To add a dashboard, either:

- **Build in the Grafana UI:** Create it interactively, then export as JSON (Share → Export → Save to file)
- **Generate with Claude Code:** Describe the metrics you want to visualize and Claude can produce a ready-to-use dashboard JSON file

Then copy the JSON to the dashboards directory on epyc, or add it to `jobs/epyc/grafana-dashboards/` in the repo and sync:

```bash
scp dashboard.json ansible@192.168.2.35:/srv/grafana/dashboards/
```

Grafana polls the directory every 30 seconds and picks up new or modified files automatically.

## Checklist

- [ ] Host volume declared in host_vars and directory created
- [ ] Nomad job file created with pinned image version
- [ ] Firewall port opened (if on a remote node)
- [ ] Caddy route added
- [ ] DNS records created (internal + external if public)
- [ ] Database created (if needed)
- [ ] Nomad variables set (if needed)
- [ ] Job deployed and verified healthy
- [ ] App accessible via browser
- [ ] Backup coverage confirmed
- [ ] Alert rules added (if needed)
- [ ] Dashboard created (if needed)
