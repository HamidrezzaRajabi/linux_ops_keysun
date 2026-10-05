# Adding a role (ssh_hardening, docker, ntp, monitoring, backup, ...)

1. `roles/<name>/{defaults,tasks,handlers,templates,meta}`; prefix every variable with `<name>_`.
2. `meta/main.yml`: `dependencies: [ {role: preflight} ]` (OS check + `preflight_sudo_impl`).
3. Tunables in `defaults/main.yml`, constants in `vars/main.yml`, data in `inventories/<env>/group_vars`.
4. Validate input with `assert` first; use modules, not `shell`; handlers for restarts; honour `--check`/`--diff`.
5. `playbooks/<name>.yml` with `serial`, `max_fail_percentage: 0`, one tag; add it to `playbooks/site.yml`
   **only if it is safe to run by default**. Keep risky roles (ssh_hardening) out of `site.yml`.
6. `make lint syntax check`, then the lab VM snapshot, then `make idempotence`.

Never put tunables in `vars/` (it overrides inventory) and never put passwords in an inventory.
