# pve_upgrade

Ansible role for in-place, one-host-at-a-time upgrades of Proxmox VE
clusters. Handles both major-version hops:

- **7 → 8** (Debian bullseye → bookworm)
- **8 → 9** (Debian bookworm → trixie)

Proxmox does not support skipping a major version — a 7.x host must go
**7 → 8 → 9** as two separate runs of this role. There is no combined
7 → 9 path.

This replaces two earlier separate roles/bugfixes a single parameterized
role driven by `pve_upgrade_path`.

## Requirements

- Ansible 2.14+
- SSH access to Proxmox VE hosts with sudo/root privileges
- Out-of-band access (iDRAC/IPMI/console) to every host you're upgrading —
  a botched network interface rename or a failed dist-upgrade can take a
  host off the network mid-run. Don't run this against a host you can only
  reach over its own network.
- For clustered nodes: a quorate cluster before you start (checked
  automatically unless `require_quorum: false`)
- Tested, verified backups of VMs/CTs and `/etc/pve` before you start —
  this role backs up config files as a safety net for the upgrade
  mechanics, it is **not** a substitute for real VM/CT backups.

## Role Variables

See `defaults/main.yml` for the full list. The ones you'll actually touch:

| Variable | Default | Purpose |
|---|---|---|
| `target_host` | `""` | Inventory host/group to run against — pass with `-e` |
| `pve_upgrade_path` | `7to8` | `7to8` or `8to9` — selects codenames, checker binary, source-file fixups |
| `require_quorum` | `true` | Set `false` for standalone (non-clustered) hosts |
| `fix_interface_naming` | `true` | Only applies a rename if the *old* interface name is actually present |
| `interface_map` | `eno1→eno1np0`, `eno2→eno2np1` | Extend this list if your hardware uses different NIC names |
| `pve_backup_etc_pve` | `true` | Tars up `/etc/pve` to `/tmp` before making changes |

`vmid` is **not** a variable you set — it's discovered live on the target
host at pre-flight time (`qm list`) and used to drive the VM
stop/verify steps.

## Usage

### Phase 1: PVE 7 → 8

```bash
ansible-playbook pve_upgrade.yml \
  -e target_host="pve-node01" \
  -e pve_upgrade_path="7to8" \
  --tags "pre_flight,apt_update_tweak"
```

This stops running VMs, backs up config, and repoints apt from
bullseye/buster to bookworm — but does **not** reboot. At this point,
perform the actual Proxmox major-version upgrade step via the Proxmox GUI
or console as you normally would, per Proxmox's own 7-to-8 documentation.

Once that's done, continue with the reboot phase:

```bash
ansible-playbook pve_upgrade.yml \
  -e target_host="pve-node01" \
  -e pve_upgrade_path="7to8" \
  --tags "reboot"
```

This runs the `pve7to8 --full` checker (and **fails the play** if it
reports anything other than `FAILURES: 0` — don't proceed past a red
checker), fixes interface naming if needed, dist-upgrades, reboots, waits
for SSH, and prints `pveversion`.

Confirm the node is on 8.4.x and stable before touching PVE 9. Repeat for
every node in the cluster, one at a time (`serial: 1` is set at play
level — don't remove it).

### Phase 2: PVE 8 → 9

Only start this once **every** node in the cluster is on the latest 8.4.x
and you've confirmed Ceph (if used) is on 19.2 Squid.

```bash
ansible-playbook pve_upgrade.yml \
  -e target_host="pve-node01" \
  -e pve_upgrade_path="8to9" \
  --tags "pre_flight,apt_update_tweak"
```

```bash
# perform the GUI/manual portion of the 8->9 upgrade if applicable, then:
ansible-playbook pve_upgrade.yml \
  -e target_host="pve-node01" \
  -e pve_upgrade_path="8to9" \
  --tags "reboot"
```

Same structure, but this run uses the `pve8to9 --full` checker and
repoints sources from bookworm to trixie. Only run against one node at a
time — this is enforced by `serial: 1` in the playbook.

## What each phase does

**pre_flight**
- Checks cluster quorum (skip with `require_quorum: false` on standalone hosts)
- Discovers currently-running VMs directly on the host (`qm list`) — not
  round-tripped through the controller, so it can't silently go stale
- Backs up apt sources, `/etc/network/interfaces`, `/etc/passwd`,
  `/etc/resolv.conf`, and `/etc/pve` to `/tmp`

**apt_update_tweak**
- Stops running VMs and polls `qm list` until they actually report stopped
  (not a blind `wait_for` sleep)
- Runs `update-grub` asynchronously and waits for it
- Checks for stuck apt/dpkg processes and **fails the play** rather than
  force-killing them — SIGKILL mid-transaction is how a dpkg database gets
  corrupted, not just a workaround for a stuck lock
- Clears stale dpkg/apt lock files, runs `dpkg --configure -a`
- Upgrades all packages on the *current* release first
- Repoints the codename (bullseye/buster→bookworm, or bookworm→trixie) in
  apt sources
- Refreshes the cache and upgrades on the new codename

**reboot**
- Runs the release-appropriate checker (`pve7to8 --full` /
  `pve8to9 --full`) and fails the play on any reported failure
- Fixes interface naming only if the *old* name is actually present on the
  host (word-boundary matched, so it won't mangle `eno10`/`eno11`/etc. the
  way a bare substring replace does)
- `apt-get dist-upgrade`, reboot, wait for SSH
- Prints `pveversion`
- Re-checks quorum after the reboot and warns (does not fail) if the node
  isn't back to quorate — investigate before moving to the next node

## Verification

After each node's `reboot` phase:

```bash
ssh root@pve-node01 pveversion
ssh root@pve-node01 pvecm status
ssh root@pve-node01 qm list        # confirm VMs you stopped are back up if auto-start expected
ssh root@pve-node01 ip -o link show
```

For 8→9 specifically, also check the things the 9-series checker doesn't
always catch: LVM autoactivation defaults, any pinned kernel needed for
PCI passthrough, and any containers on cgroup v1 (very old CT templates)
that will no longer start.

## Rollback / troubleshooting

- **Interface renamed and host dropped off the network**: use out-of-band
  access, then reverse the specific `interface_map` entry in
  `/etc/network/interfaces` and `systemctl restart networking`.
- **apt/dpkg left in a bad state**: don't force-kill processes. Check
  `ps aux | grep -E 'apt|dpkg'`, let any real transaction finish, then
  `dpkg --configure -a` and re-run the role from `apt_update_tweak`.
- **Checker (`pve7to8`/`pve8to9`) failed**: the play stops before
  rebooting — fix what it flagged and re-run the `reboot`-tagged phase
  only.
- **Config file restore**: backups live at `/tmp/*.bk.<path>` (per-file)
  and `/tmp/etc-pve-backup-<path>-<timestamp>.tar.gz` on the target host
  itself — copy them off-host after every run, `/tmp` is not durable
  storage.
- **Cluster not quorate after upgrade**: do not proceed to the next node.
  Resolve quorum first — bringing down a second node in a non-quorate
  cluster risks a full outage.

## Known limitations / things this role does not do for you

- Does not migrate running guests off a node before upgrade — if you need
  live-migration-based zero-downtime upgrades, that's a separate step
  before invoking this role.
- Does not manage HA groups/rules across the upgrade (PVE 9 replaces HA
  Groups with HA Rules) — review HA config manually post-upgrade.
- Does not handle Ceph version upgrades — sequence those yourself against
  Proxmox's Ceph compatibility matrix before running the 8to9 path.
- Assumes standard Proxmox/Debian package sources — third-party repos
  (beyond the Dell/Zabbix entries already parameterized in
  `apt_sources_files`) need to be added to that list or handled manually.

## License

MIT

## Author

Darren Lavery
