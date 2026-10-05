# Testing

## Every change
```bash
make lint      # yamllint + ansible-lint (profile: production)
make syntax    # ansible-playbook --syntax-check
make check     # --check --diff against the lab inventory
make idempotence PB=playbooks/users.yml LIMIT=test_server   # applies twice, 2nd run must be changed=0
```
Use `INV=inventories/production LIMIT=<host>` for production.

## First-run checklist on a snapshot of the lab VM (Ubuntu 26.04 and one of 22.04/24.04)
Take a snapshot, run each step, roll back if anything is odd. These are the points I could not
confirm without running Ansible:

1. `ansible -m ping -b test_server` works (become via sudo-rs on 26.04).
2. `sudo --version | head -1` ... confirm the first line contains `sudo-rs` on 26.04 (this is how `preflight` decides).
3. `ansible-playbook playbooks/users.yml --check --diff` works for an account that does not exist yet.
4. Apply, then apply again: second run `changed=0`, especially the user task (`expires`, `password: '*'`, `groups`).
5. `sudo -l -U <user>` is not used by the role; check by hand that a scoped user can run exactly their commands.
6. Revoke a throwaway user: `groups: ""` clears all supplementary groups (`id <user>`), `pkill` finds nothing -> not an error.
7. `ls /etc/audit/plugins.d/syslog.conf` exists on 26.04; if not: `dpkg -S plugins.d/syslog.conf`, then set `auditd_syslog_plugin_conf`.
8. `ls /etc/audit/rules.d/` and `auditctl -l`: `execve`, `identity`, ... keys present; if the host has no stock `audit.rules`, `00-clear.rules` keeps reloads clean.
9. Upgrade test: on a 24.04 host with the old `00-io-logging`, upgrade to 26.04 (or fake sudo-rs), run `audit.yml`: the fragment is removed and `visudo -c` passes.
10. `sshd -T -C user=<u>,host=localhost,addr=127.0.0.1` works (used by the post-run check).

## Zero-diff proof for the logging roles
On a host the old project already configured: `ansible-playbook playbooks/logging.yml --check --diff` must show no change
(the old `execve.rules` is rewritten by `auditd`, also unchanged).

## Molecule (optional, later)
Worth adding for `user_provisioning` (Docker driver). Not for `auditd`/`rsyslog_forward`: the kernel audit
netlink is not available in unprivileged containers; use the lab VM.
