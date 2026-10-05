# Design rationale (historical)

This is the design reasoning from the first version of the project (security analysis, why Ansible,
what auditing can and cannot prove). It is kept because the reasoning still holds. Where it describes
behaviour, **README.md and docs/OPERATIONS.md win**. Known differences from the code:

- `disabled` users: keys and sudoers are **removed** (not kept); the shell is nologin and the account is locked/expired.
- `state: absent` **revokes** (lock/expire/strip); the account is only deleted with `users_purge=true`.
- There is no SSH smoke test as the new user; the run ends with `visudo -c`, account checks and an `sshd -T` AllowUsers check.
- Revocation is logged through syslog (`ansible-revoke`, authpriv), not to a local markdown file.
- Variable names changed (see README); role layout is in README. The rules/paths below use the old names.
- On Ubuntu 26.04 (sudo-rs) there are no sudo I/O transcripts.

---

## 1. Analysis first: don't blindly implement the spec

Before any code, here's where the literal requirements need pushback or
clarification. This is the most important section — read it before touching
the playbooks.

### 1.1 "Passwordless SSH" ≠ "disable all password auth on the box"

These are two different controls and should **not** be conflated:

- **Per-user passwordless sudo/login** — giving a user an SSH key and no
  password — is fine and is what this project does.
- **`PasswordAuthentication no` in `sshd_config`** is a host-wide setting.
  Flipping it is *correct practice* for a hardened fleet, but it:
  - Affects every user on the box, including break-glass/local accounts,
    not just the ones this tool manages.
  - Can lock you out instantly if it's pushed before every relevant admin
    has a working key installed and tested.
  - Should be a **separate, explicit role** (`sshd_hardening`, not included
    here) applied only after you've verified key-based login works for
    every account that needs to survive the change, and ideally gated
    behind a canary host + `serial: 1` + a rollback window.

  **Recommendation:** ship user provisioning and SSH hardening as two
  independent playbooks. Never bundle "add a user" with "harden sshd" in
  the same idempotent run — a bad user var shouldn't be able to cascade
  into a global lockout.

### 1.2 Unrestricted sudo is not appropriate by default

The input schema in the request (`sudo: true/false`) implies all-or-nothing
root. That's a real risk: a compromised key with unrestricted `NOPASSWD: ALL`
sudo is equivalent to a compromised root key, and defeats the purpose of
having named accounts at all (you get attribution for the *login*, but not
for what happens after `sudo -i`).

**Recommendation:** extend the schema so `sudo` is not a boolean but a
policy:

```yaml
sudo:
  enabled: true
  mode: full        # full | scoped | none
  commands:         # only used when mode: scoped
    - /usr/bin/systemctl restart nginx
    - /usr/bin/docker
  require_password: false   # NOPASSWD or not
```

Default to `mode: scoped` with an empty command list (i.e., sudo group
membership without a working rule) so a misconfigured entry fails closed,
not open. `full` should be an explicit, reviewable opt-in per user — treat
it as a privileged-access request, not a default.

### 1.3 Docker group = root, full stop

Being in the `docker` group is **not** a permissions boundary — it's
equivalent to passwordless root, because you can bind-mount `/` into a
container and chroot into it. The original spec's `docker: true/false` flag
correctly makes this *configurable*, but the design must also:

- Document this explicitly to whoever approves access requests (not just
  in code comments — in the PR/change-ticket template).
- Treat `docker: true` requests with the same scrutiny as `sudo: full`.
- Where possible, prefer **rootless Docker** or **Podman** (which doesn't
  require a privileged group at all) for new hosts, and reserve classic
  Docker-group access for hosts that genuinely need it.

This project implements the flag as requested but surfaces a loud warning
in the play output and in generated docs any time it's set to `true`.

### 1.4 What auditing can and can't actually tell you

- **`auditd`** can reliably tell you: who logged in when (via PAM/audit
  integration), file/permission changes on watched paths, and — with the
  `execve` audit rule — every command executed by every process, including
  ones run via sudo. This is powerful but **noisy and expensive** at scale;
  full `execve` auditing on busy servers can generate large volumes of
  audit events and there's real disk/CPU cost. It's also inherently
  incomplete: a user can trivially rename a binary, use scripting-language
  built-ins, or write a static binary to work around simple command
  matching, and `execve` auditing captures the exec syscall but not
  everything a process does after that.
- **`sudo` logging** (`Defaults logfile=`, `log_input`, `log_output`) gives
  you a session transcript (I/O logging) of what happened *inside* a sudo
  session — closer to a screen recording than a syscall log — which is
  more useful for human review than raw audit records, but is also
  bypassable by anyone who can invoke a shell that itself spawns
  unlogged subprocesses in creative ways, and it only covers sudo, not
  direct root logins.
- **SSH auth logs** (`journald`/`/var/log/auth.log` or `/var/log/secure`)
  reliably tell you *who authenticated, from where, with which key
  fingerprint, when* — this is your strongest, hardest-to-fake signal and
  the foundation for "who did X" attribution, because it ties a Linux
  username to a specific SSH key back to a specific person.

**Bottom line: auditd alone is not sufficient.** The realistic, achievable
posture is defense in depth:

1. SSH logs → identity attribution (who logged in as whom).
2. sudo session I/O logging → human-readable record of privileged sessions.
3. auditd execve + file-integrity watches → forensic detail and tamper
   evidence, understood as *best-effort*, not a complete transcript.
4. Ship all three off-box to a remote log collector/SIEM in near-real-time,
   because...

### 1.5 Tamper resistance: logs must leave the box

No local control (`chattr +a`, restrictive permissions on `/var/log/audit`)
stops someone with root — and sudo users are one misconfigured rule away
from root — from editing or truncating local logs. **Auditability against a
privileged local user is fundamentally a shipping problem, not a
permissions problem.** This design:

- Forwards events off the box: in the merged project `linux_logging` ships
  syslog, auth, auditd and command logs to Logstash through rsyslog.
- Can set `auditd`'s local behavior to fail secure-ish for tampering
  (`-e 2` locks the audit config until reboot, opt-in via
  `audit_lock_config`) as a deterrent, while being
  explicit that this is a speed bump, not a guarantee, against a
  determined root-equivalent user.
- Applies restrictive permissions to local log paths as defense in depth,
  not as the primary control.

### 1.6 Lockout avoidance

- Every playbook run that touches SSH/sudo config validates before
  applying: `sshd -t` for sshd config, `visudo -cf` for sudoers fragments.
- Sudoers changes are written to a temp file and validated with
  `visudo -cf` **before** being moved into `/etc/sudoers.d/`, never edited
  in place.
- `serial: 1` (one host at a time) plus a smoke-test task (SSH back in as
  the provisioned user, non-interactively, with a short timeout) is
  recommended for the first rollout to a new host group, so a bad change
  is caught on host 1 instead of fleet-wide.
- The automation never removes or disables the operator's own
  break-glass/admin account, and the design assumes at least one
  out-of-band access path (console, IPMI, cloud provider serial console)
  exists independent of SSH for genuine emergencies.

### 1.7 When to stop doing this by hand at all

Per-host user files (even automated) don't scale cleanly past a few dozen
hosts or a handful of admins — you end up reasoning about drift and
revocation across N inventories. If the server fleet or headcount grows
meaningfully, or you need features like MFA, password rotation policy, or
group-based RBAC synced with HR/offboarding, a centralized identity
provider (FreeIPA is the natural open-source fit for a Linux-only fleet;
Azure AD/Entra ID + SSSD if you're already Microsoft-centric; LDAP if you
need something more minimal) will beat maintaining this indefinitely. This
Ansible project is the right tool **now** and is designed so it wouldn't be
wasted work later — the YAML user inventory here maps cleanly onto "external
system says these users/keys/groups exist," so IdP integration later is an
evolution, not a rewrite.

---

## 2. Recommended approach: Ansible

| Option | Verdict |
|---|---|
| Raw Bash over SSH | Rejected as primary tool — no real idempotency model, secrets handling is manual, state tracking across N hosts is on you. Fine as a helper script *called by* Ansible, not as the orchestrator. |
| Pure Python (Fabric/Paramiko) | Rejected — you'd be reimplementing Ansible's inventory, idempotency, and privilege-escalation handling from scratch for no real benefit here. |
| Ansible | **Recommended.** Built-in idempotent modules (`user`, `authorized_key`, `template`, `copy`), native Vault for secrets, `become` for privilege escalation, mature testing story (`--check`, `--diff`, molecule), and it's already in your existing skill set. |

Ansible + a couple of small Python helper scripts (for input validation and
optional key-fingerprint verification) is the sweet spot, not Ansible vs.
Bash vs. Python as mutually exclusive.

---

## 3. Project layout

```
.
├── site.yml                   # THE playbook: logging + audit + users
├── ansible.cfg
├── requirements.yml
├── inventory/hosts.yml        # group: linux_servers
├── group_vars/all/
│   ├── users.yml              # user manifest (sample data, replace it)
│   └── vault.yml.example
├── playbooks/
│   ├── provision_users.yml    # add/update users only
│   └── revoke_user.yml        # targeted revocation, run with -e target_user=
├── roles/
│   ├── linux_logging/         # rsyslog -> Logstash JSON, bash cmd log, auditd execve
│   ├── audit_logging/         # extra audit rules, sudo I/O logging, optional lock
│   └── user_provisioning/     # users, keys, sudo, docker, revoke
└── docs/OPERATIONS.md         # day-2 runbook
```

See the code files in this project for the full implementation. Highlights
below; open each file for the complete, commented version.

---

## 4. User configuration schema (extended)

```yaml
# group_vars/all/users.yml
users:
  - username: alice
    full_name: "Alice Nkemdirim"
    state: present            # present | absent | disabled
    ssh_public_key: "ssh-ed25519 AAAA... alice@laptop"
    sudo:
      enabled: true
      mode: scoped             # full | scoped | none
      commands:
        - /usr/bin/systemctl restart nginx
        - /usr/bin/docker
      require_password: false
    docker: false
    shell: /bin/bash
    groups: []                 # extra supplementary groups if needed

  - username: bob
    state: present
    ssh_public_key: "ssh-ed25519 BBBB... bob@workstation"
    sudo:
      enabled: false
    docker: true               # flagged loudly at runtime — root-equivalent
    shell: /bin/bash
```

Secrets that legitimately need Vault here are narrow: nothing above is a
plaintext password (there are none), but if you later add service-account
passwords, API tokens, or a remote syslog shared secret, those go in
`group_vars/all/vault.yml`, encrypted with `ansible-vault`, and referenced
by variable name from the plaintext files — never inline.

---

## 5. Key security defaults baked into the roles

- Home dirs `0750`, `~/.ssh` `0700`, `authorized_keys` `0600`, all owned by
  the target user — enforced every run, not just on creation.
- `authorized_keys` is fully **managed** (`exclusive: true` in the
  `authorized_key` module) so a key removed from the YAML manifest is
  actually removed from the host, not just "not added again."
- Sudoers fragments are one file per user under `/etc/sudoers.d/<user>`,
  mode `0440`, owned by `root:root`, validated with `visudo -cf` before
  being put in place, and named so `ls /etc/sudoers.d/` alone tells you
  who has what.
- `docker: true` triggers a task that prints a visible warning in play
  output (and can be wired to fail the run unless `-e
  acknowledge_docker_risk=true` is passed) rather than silently granting
  root-equivalent access.
- Revocation is a first-class operation, not "set state: absent and hope,"
  covered in Section 7.

---

## 6. Auditing configuration (what actually gets deployed)

Shipping to Logstash and execve auditing are owned by `roles/linux_logging`
(rsyslog JSON forwarding, bash command log on local6, auditd events on local5,
rule key `user_commands`). `roles/audit_logging` adds:

1. `auditd` rules (`templates/audit.rules.j2`):
   - `/etc/passwd`, `/etc/shadow`, `/etc/group`, `/etc/gshadow`,
     `/etc/sudoers`, `/etc/sudoers.d/`, `/etc/ssh/sshd_config`, `/etc/pam.d/`
     watched for tampering,
   - the log pipeline itself (`/etc/rsyslog.conf`, `/etc/rsyslog.d/`,
     `/etc/profile.d/`),
   - clock changes and kernel module load/unload by logged-in users,
   - `/etc/audit/` and the audit binaries.
   Optional: `audit_log_root_execve: true` adds a rule for every command run
   with euid 0 (noisy).
2. `sudo` I/O logging (`Defaults logfile=/var/log/sudo.log`,
   `Defaults log_input,log_output`) for human-readable session transcripts.
   These transcripts stay on the server.
3. Optional `audit_lock_config: true` writes `-e 2` (lock audit config until
   reboot) to `zz-finalize.rules`. Off by default; see `docs/OPERATIONS.md`.

---

## 7. Lifecycle workflows

### Add a new user
```
ansible-playbook playbooks/provision_users.yml --limit webservers --check --diff   # dry run
ansible-playbook playbooks/provision_users.yml --limit webservers                  # apply
```

### Update a user's SSH key
Edit their `ssh_public_key` in `group_vars/all/users.yml`, re-run
`provision_users.yml`. `exclusive: true` on `authorized_keys` ensures the
old key is removed automatically.

### Revoke a user (recommended path)
```
ansible-playbook playbooks/revoke_user.yml -e target_user=bob --check --diff
ansible-playbook playbooks/revoke_user.yml -e target_user=bob
```
This playbook, independent of the full user list, immediately:
1. Removes all `authorized_keys` entries for that user (fastest way to cut
   off access — doesn't wait for a full run).
2. Removes their `/etc/sudoers.d/<user>` file.
3. Removes them from `docker`/other supplementary groups.
4. Locks the account (`passwd -l`) and expires it (`chage -E 0`) rather
   than immediately `userdel`, so their file ownership doesn't become
   orphaned and there's a paper trail before deletion.
5. Logs the revocation action itself (who ran the playbook, when, against
   whom) to a local `docs/revocation_log.md`-style Ansible fact/callback —
   wire this to your ticketing system in production.

### Fully remove a user later
Set `state: absent` in the manifest and re-run `provision_users.yml`, or
add a `purge_user.yml` step once you're comfortable the account is no
longer needed for any forensic/handover purpose.

### Temporarily disable
Set `state: disabled` — role locks the password and keeps
`authorized_keys`/sudoers in place but adds a `--` no-login shell, so
re-enabling is a one-line revert instead of full re-provisioning.

---

## 8. Testing strategy

- `ansible-playbook ... --check --diff` on every change before a real run.
- `ansible-lint` and `yamllint` in CI on every PR to the manifest/roles.
- A disposable Vagrant/Docker-based test host (or Molecule with the
  `docker` driver) to run the full role against a throwaway container and
  assert: user exists, key auth works, sudo rule validates, docker group
  membership matches spec, audit rules loaded (`auditctl -l`).
- A non-destructive "smoke test" task at the end of `provision_users.yml`
  that attempts an SSH connection as the new user (via `wait_for_connection`
  or a local `ssh -o BatchMode=yes` check) before declaring success.

## 9. Rollback / recovery

- Keep the manifest in git; `git revert` + re-run is your primary rollback
  path for user/permission changes.
- Because sudoers/`authorized_keys` are validated before being written,
  the most likely failure mode is "task fails, nothing applied" rather
  than "bad config applied" — Ansible won't move an invalid sudoers
  fragment into place.
- For sshd-level changes (not part of this role, see 1.1), always keep an
  existing, working SSH session open in a second terminal while applying
  changes, and never close it until you've verified a fresh connection
  succeeds.
- Out-of-band console access (cloud provider serial console, IPMI, KVM)
  is the backstop for anything Ansible-over-SSH can't fix because SSH
  itself is broken.

---

## 10. Deploying this automation

```bash
git clone <this-repo>
cd <project-dir>
ansible-galaxy collection install -r requirements.yml   # if any external collections used
ansible-vault create group_vars/all/vault.yml           # if/when real secrets are added
ansible-playbook site.yml --limit <host-or-group> --check --diff
ansible-playbook site.yml --limit <host-or-group>
```
