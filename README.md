# Homestar Ansible Bootstrap

This repository is now the Ansible control repo for the homestar migration from
Talos/Kubernetes to Ubuntu + Nomad.

The first implemented milestone is bootstrapping `epyc` from a fresh Ubuntu
24.04 install that is still on DHCP into the planned baseline:

- static IPs on `enp6s0f1`: `192.168.2.35/24` and `192.168.2.202/24`
- default gateway `192.168.2.1`
- DNS `192.168.2.1`
- core packages, time sync, basic directories, and a minimal UFW baseline

## Repository Layout

- `ansible.cfg`: local Ansible defaults for this repo
- `requirements.yml`: required collections
- `inventories/production/`: canonical host inventory and variables
- `playbooks/bootstrap.yml`: first-run `epyc` bootstrap from DHCP to static IPs
- `playbooks/site.yml`: baseline playbook for hosts already reachable at their
  canonical addresses
- `roles/base/`: first-pass OS baseline and `epyc` netplan management

## Controller Prerequisites

Install Ansible on the machine you will run playbooks from, then install the
required collections:

```bash
ansible-galaxy collection install -r requirements.yml
```

Bootstrap assumes:

- the target host already has an SSH-reachable `ansible` user
- `ansible` can use `sudo`
- you can reach the temporary DHCP lease for `epyc`

If the installer-assigned DHCP address is not `192.168.2.35`, keep the
inventory canonical and override `ansible_host` only for the first bootstrap
run.

## First Run

Run the bootstrap against `epyc` using its current DHCP address:

```bash
ansible-playbook playbooks/bootstrap.yml -e ansible_host=192.168.2.X -k -K
```

`bootstrap.yml` will:

1. ensure Python is present
2. disable cloud-init network rendering
3. install the final netplan for `enp6s0f1`
4. wait for SSH to come back on `192.168.2.35`
5. finish the base OS baseline over the canonical address

After `epyc` is on its final address, future runs should use the inventory as-is:

```bash
ansible-playbook playbooks/site.yml -l epyc
```

The repo is configured to use `~/.ssh/id_ed25519_homestar` for SSH, and the
`base` role installs `~/.ssh/id_ed25519_homestar.pub` for the remote admin user
during the baseline pass. The `base` role also installs a validated sudoers
drop-in so the `ansible` user has passwordless sudo.

That means the first password-based bootstrap still needs `-k -K`, but later
runs should not need either flag as long as the SSH key remains available on
the controller.

## Secrets and External Integrations

Secrets remain outside the repository. `inventories/production/group_vars/all.yml`
stores placeholder or reference values only.

Planned integrations already have placeholders ready for later roles:

- Cloudflare API token via 1Password
- opnSense API key and secret via 1Password
- PostgreSQL superuser password via 1Password
- Cloudflare tunnel ID

The expected 1Password item references are tracked in
`inventories/production/group_vars/all.yml`.

## Notes

- The legacy migration helpers in `scripts/` are still useful during cutover,
  but they are separate from the new Ansible control-repo flow.
- Only `epyc` networking is automated in this first pass because its interface
  name is known. The other nodes can be added once their Ubuntu NIC names are
  confirmed.
