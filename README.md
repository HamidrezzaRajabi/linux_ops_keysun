# linux-ops

Ansible project for **log forwarding, audit baseline and user provisioning** on Ubuntu
servers (20.04, 22.04, 24.04 and **26.04**). Each concern is its own role and its own
playbook; `playbooks/site.yml` runs them all.

```bash
ansible-galaxy collection install -r requirements.yml

# 1. once per host: create the key-only automation account (no passwords in files)
ansible-playbook playbooks/bootstrap_automation_user.yml -e ansible_user=<admin> -k -K \
    -e "automation_public_key='ssh-ed25519 AAAA... ansible_deploy@controller'" --limit test_server

# 2. always dry-run first, one host first
ansible-playbook playbooks/site.yml --check --diff --limit test_server
ansible-playbook playbooks/site.yml --limit test_server
```

The default inventory is `inventories/lab`. Production is always explicit:
`-i inventories/production`.

## Layout

```text
linux-ops/
├── ansible.cfg  requirements.yml  Makefile  .ansible-lint  .yamllint  .gitignore
├── inventories/
│   ├── lab/         hosts.yml, group_vars/{all,linux_servers}, host_vars/
│   └── production/  (same shape)
├── playbooks/
│   ├── site.yml                      imports logging, audit, users
│   ├── logging.yml                   rsyslog_forward + command_logging
│   ├── audit.yml                     auditd + sudo_io_logging
│   ├── users.yml                     user_provisioning
│   ├── users_revoke.yml              targeted revocation
│   └── bootstrap_automation_user.yml key-only automation account
├── roles/
│   ├── preflight/          OS check (Ubuntu 20.04-26.04), detects sudo vs sudo-rs
│   ├── user_provisioning/  users, keys, sudo, docker gate, revoke, validation
│   ├── auditd/             package, service, baseline + execve rules, syslog plugin, lock
│   ├── sudo_io_logging/    sudo session transcripts (classic sudo only)
│   ├── rsyslog_forward/    rsyslog -> Logstash JSON
│   └── command_logging/    bash command log (local6)
├── scripts/idempotence-check.sh
└── docs/  OPERATIONS.md  TESTING.md  ADDING_A_ROLE.md  DESIGN.md
```

Data lives in `inventories/<env>/group_vars` and `host_vars` (so every playbook gets it),
tunables in `roles/*/defaults`, constants in `roles/*/vars`. Playbooks stay thin.

## Run one concern at a time

| Goal | Command |
|---|---|
| Users only | `ansible-playbook playbooks/users.yml --check --diff` |
| Audit only | `ansible-playbook playbooks/audit.yml --check --diff` |
| Log forwarding only | `ansible-playbook playbooks/logging.yml --check --diff` |
| Revoke now | `ansible-playbook playbooks/users_revoke.yml -e target_user=bob -e change_ref=INC-123` |
| Sub-parts | `--tags rsyslog`, `bash`, `auditd`, `sudo`, `packages`, `verify`, `validate` |
| Speed up | `-e rollout_batch=10` (default is 1 host at a time; a failure stops the rollout) |

## Ubuntu 26.04

Checked against package and project pages; **not run on a real 26.04 host** (see "Not tested").

- **sudo-rs is the default `sudo`.** It rejects `logfile`, `log_input` and `log_output`
  (`visudo -c -f` reports "unknown setting"), so the old `00-io-logging` fragment would break
  sudo's config. `preflight` detects the implementation; `sudo_io_logging` writes the fragment only
  for classic sudo and *removes* a leftover one on sudo-rs (e.g. after a 24.04 -> 26.04 upgrade).
  On 26.04 there are no sudo session transcripts; who ran what via sudo is still in syslog
  (authpriv, forwarded) and the auditd execve rule covers every command.
- **audit is 4.1.2** and `audispd-plugins` is in *universe*. The role installs both packages and
  fails with a clear message if `/etc/audit/plugins.d/syslog.conf` is missing (the path is a variable).
- **rsyslog 8.2512**: the forwarding config is unchanged and valid there.
- Sudoers fragments are written without dots in the file name and with `NOPASSWD: ALL`
  (with a space), which both sudo and sudo-rs accept.
- 20.04 is past standard support; it stays in the allowed list for now.

## What changed (review findings fixed)

| ID | Fix |
|---|---|
| A1 | Passwords removed from the inventory; key-only `ansible_deploy` account via `bootstrap_automation_user.yml` |
| A2 | Revocation: no `ignore_errors`; removes `authorized_keys` and `authorized_keys2`, sudoers fragment, all supplementary groups; ends processes; nologin + lock + expire; logs to syslog |
| A3 | Lock-out guards: root, the connecting account, system accounts (uid < 1000) can't be revoked or managed |
| A4 | `groups:` can't carry sudo/docker/adm/lxd/...; docker membership is removed when not granted; `users_exclusive_groups` for full control |
| A5 | `group_vars` moved into the inventory directories |
| B1/B2/B3 | Real validation (`validate.yml`); dotted usernames get a safe sudoers file name; home path read from the account |
| B4 | `--check` works for new users (dependent tasks skipped) |
| B5 | The fake smoke test is replaced by `visudo -c`, account checks and an `sshd -T` AllowUsers check |
| B6 | Revocation is logged through syslog (forwarded off-host), `change_ref` required |
| B7 | sudo I/O logging: output on, input off (passwords), 30-day retention, sudo-rs aware |
| B8 | One `auditd` role owns package, service, rules and reload |
| B10 | One playbook per concern, `site.yml` imports them |
| C1/C2 | `sshd_config.d`, `/etc/security`, `login.defs` watches; locked-config detection with a clear "reboot needed"; baseline keys verified |
| C3 | `id`/`gpasswd` shell-outs replaced by `getent` and the `user` module |
| C4 | `expires` is set explicitly (re-enabling a revoked user works) |
| C5/C6/C7 | `require_password: true` rejected (no passwords exist); scoped commands must be absolute; multiple keys supported |
| C8/C9 | Docs corrected; accounts created with `*` password |
| D | `deprecation_warnings` back on; lint configs, Makefile, `.gitignore` |

Not changed on purpose: `linux_logging` content. Its templates are now split into
`rsyslog_forward` and `command_logging`/`auditd` and render **byte-identical** output for the same values.
Transport hardening (TCP/RELP+TLS instead of UDP, review item C10) is left for you to decide with the Logstash side.

## Renamed variables

| Old | New |
|---|---|
| `users` | `managed_users` (and `ssh_public_key` may now also be `ssh_public_keys: [...]`) |
| `acknowledge_docker_risk`, `purge` | `users_acknowledge_docker_risk`, `users_purge` (old names still work) |
| `default_shell`, `*_mode` | `users_default_shell`, `users_*_mode` |
| `logstash_host/port/proto` | `rsyslog_forward_host/port/proto` |
| `rsyslog_max_severity`, `rsyslog_queue_*` ... | `rsyslog_forward_*` |
| `bash_log_facility`, `bash_log_tag`, `bash_audit_script` | `command_logging_facility/tag/script` |
| `audit_syslog_facility`, `audit_rules_key`, `audit_min_auid` | `auditd_syslog_facility`, `auditd_execve_key`, `auditd_min_auid` |
| `audit_lock_config`, `audit_log_root_execve` | `auditd_lock_config`, `auditd_log_root_execve` |

## First run on hosts that already have the old project applied

Expect these one-time changes in `--check --diff`; the logging templates show **no** change.

- `/etc/sudoers.d/<user>`: header text and `NOPASSWD:ALL` -> `NOPASSWD: ALL`.
- `/etc/audit/rules.d/user-provisioning.rules` removed; `baseline.rules` and `00-clear.rules` added (a few extra watches).
- `/etc/sudoers.d/00-io-logging` rewritten (no `log_input`, no `logfile`) plus `/etc/tmpfiles.d/sudo-io.conf`.
- `authorized_keys2` removed for managed users.
- Docker group membership removed for any managed user without `docker: true`.

## Not tested

I could not run Ansible here (no installation, no network). What I did run: YAML parse of all files, Jinja
compile of every template/expression, a byte-for-byte render comparison of the old and new logging templates,
and the validation rules against 21 good/bad manifests in an Ansible-like Jinja environment.
Run the checklist in `docs/TESTING.md` on a snapshot of your lab VM before anything else.
