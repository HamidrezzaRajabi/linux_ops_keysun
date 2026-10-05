# Day-2 Operations

## First-time setup of a host
1. Generate a controller key: `ssh-keygen -t ed25519 -f ~/.ssh/ansible_deploy_ed25519 -C ansible_deploy@controller`
2. Bootstrap (you type the existing admin's SSH and sudo passwords; nothing is stored):
   `ansible-playbook playbooks/bootstrap_automation_user.yml -e ansible_user=<admin> -k -K -e "automation_public_key='$(cat ~/.ssh/ansible_deploy_ed25519.pub)'" --limit <host>`
3. Check: `ansible -m ping -b <host>` (on 26.04 this also proves Ansible's `become` works with sudo-rs).
4. Change the old admin password anywhere it was reused.

First connection to a new host: `host_key_checking` is on; add the host key first with `ssh-keyscan -H <ip> >> ~/.ssh/known_hosts` (compare the fingerprint).

## Add a user
1. Add an entry to `inventories/<env>/group_vars/<group>/users.yml` (schema at the top of that file).
2. `ansible-playbook playbooks/users.yml --limit <host> --check --diff`, review sudo mode and `docker:`.
3. Apply. The run ends with checks: `visudo -c`, account state, `sshd -T` AllowUsers.

## Rotate or change keys / sudo scope
Edit `ssh_public_keys` or `sudo:` in the manifest and re-run. Keys not in the manifest are removed; the sudoers fragment is replaced and validated.

## Revoke (incident or offboarding)
```
ansible-playbook playbooks/users_revoke.yml -e target_user=<name> -e change_ref=<ticket> --check --diff
ansible-playbook playbooks/users_revoke.yml -e target_user=<name> -e change_ref=<ticket>
```
Removes keys, sudo, all supplementary groups, ends sessions, sets nologin, locks and expires. The account is deleted only with `-e users_purge=true`. Then set `state: absent` in the manifest.
Look for the record: `ansible-revoke` in syslog/authpriv (also in Logstash).
Re-enabling later: set `state: present` again; expiry and shell are reset by the next run.

## Temporarily disable
`state: disabled`: nologin shell, expired/locked, keys and sudo removed, account and files kept.

## Strict group control
`users_exclusive_groups: true` makes the manifest the complete list of supplementary groups for managed users. Run `--check --diff` first; it strips groups not in the manifest.

## Locking the audit config (`auditd_lock_config`)
Off by default. With `-e auditd_lock_config=true`, rules become immutable until reboot; later rule changes are written but fail with "reboot needed". Turn on only when rules are final, then reboot once.

## Rolling out
1. `--limit <canary> --check --diff`, then apply to the canary.
2. Log in as a provisioned user from a second terminal before closing your working session.
3. Roll on: default is one host at a time and a failure stops the run; `-e rollout_batch=10` once the canary is happy.
Keep out-of-band console access for the rollout window.

## Who did X?
1. SSH auth: `journalctl -u ssh` / `/var/log/auth.log` for the user and key.
2. sudo: syslog authpriv (also in Logstash) shows who ran which command. On **classic sudo** `/var/log/sudo-io` has session transcripts (output only by default); **sudo-rs (26.04) has none**.
3. `ausearch -k user_commands` (every command of logged-in users) and `-k privilege_escalation`/`identity` for tampering. Best-effort, see docs/DESIGN.md.
4. Prefer the copy in Logstash/Kibana: a local root user could have edited local logs.

## Log transport
`rsyslog_forward_proto: udp` is lossy and unauthenticated. For audit/auth/command logs consider `tcp` (set in `inventories/<env>/group_vars/all/main.yml`) after enabling a TCP input on Logstash; RELP/TLS is stronger still.
