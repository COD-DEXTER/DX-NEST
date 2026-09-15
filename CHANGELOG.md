# Changelog

## v2.3.0 — Public SSH (via Cloudflare)

Scope: adds a fully independent Remote Access module — menu item
**[10] Public SSH (via Cloudflare)** — that exposes the guest Ubuntu
SSH service through a Cloudflare Tunnel, without ever exposing
QEMU's `127.0.0.1:2222` forward publicly and without changing
anything about the existing QEMU lifecycle, menu, or CLI.

### Added
- **Two separate credentials, on purpose.** A scoped **Cloudflare API
  Token** (`remote/cloudflare-api.token`, 0600) is used only during
  Setup/Repair to talk to `api.cloudflare.com`. The **Cloudflare
  Tunnel Token** (`remote/cloudflared.token`, 0600) is a different
  credential that `cloudflared` actually runs with. `cloudflared` is
  never invoked with the API Token, and the API Token is never a
  `config.env` key — only `REMOTE_ACCESS_PROVIDER`, `CLOUDFLARE_SSH_HOST`,
  `CLOUDFLARE_ACCOUNT_ID`, and `CLOUDFLARE_TUNNEL_ID` (all non-secret)
  are.
- **`remote_setup`**: takes the API Token + SSH hostname, auto-discovers
  the Cloudflare account (`GET /accounts`) or asks for the Account ID
  if that isn't possible with the token's permissions, then drives the
  whole rest of the setup through the Cloudflare API:
  `cf_find_or_create_tunnel` → `cf_configure_route` → `cf_get_tunnel_token`
  → best-effort `cf_try_create_dns_record`. The user never has to open
  the Zero Trust dashboard or copy a Tunnel Token by hand.
- **Idempotent by design.** Tunnels are named deterministically
  (`dx-nest-<hostname>`); re-running Setup reuses the existing tunnel
  (verified live, not just by the locally-recorded ID) instead of
  creating `dx-nest-ssh-1`, `dx-nest-ssh-2`, ... — see TEST_REPORT.md.
- **`remote_repair`**: if the runtime Tunnel Token file is missing or
  empty but the API Token + Tunnel ID are still on file, it re-fetches
  the Tunnel Token automatically instead of forcing Setup from scratch.
  Repair never touches the VM disk, VM SSH identity, or QEMU networking.
- **`[6] Open Cloudflare Token Setup`**: prints the plain, undecorated
  `https://dash.cloudflare.com/profile/api-tokens` URL with the exact
  manual steps (Custom Token → Account → Cloudflare Tunnel → Edit).
  Deliberately does **not** append a `permissionGroupKeys=...` query
  string — that parameter is not officially documented by Cloudflare
  for account-scoped tokens (an open, unresolved upstream docs issue
  confirms this), so DX-NEST doesn't guess a permission-group key it
  can't verify.
- **Process management for `cloudflared`** mirrors QEMU's: own PID
  file, own log (`remote/cloudflared.log`, rotated), own `flock`
  (`remote/.remote.lifecycle.lock`, independent of QEMU's lifecycle
  lock), identity-verified PID checks (cmdline + `/proc/<pid>/exe`
  both checked against the token-file path — never a blind
  `kill $(cat pidfile)`), stale-PID cleanup, graceful TERM →
  wait → KILL shutdown.
- **`dx remote status|start|stop|restart|info|setup|repair|disable`** CLI
  subcommands, alongside the interactive submenu.
- Non-secret `CLOUDFLARE_ACCOUNT_ID` / `CLOUDFLARE_TUNNEL_ID` added to
  the `config.env` whitelist and to `dx config` output (never the
  tokens themselves).

### Explicitly not implemented (by design, not an oversight)
- No OAuth flow — investigated; Cloudflare's third-party OAuth is
  Authorization-Code-only (no Device Flow for third parties), which
  would require a real hosted redirect endpoint DX-NEST doesn't have.
- No automatic Cloudflare Access policy creation.
- No Global API Key / API-Email authentication anywhere.

### Security
- API Token and Tunnel Token: hidden input, never echoed, never
  written to `config.env`, never appear in logs/status/`dx config`/
  README/CHANGELOG/TEST_REPORT, stored 0600 via temp-file + atomic
  `mv` (same pattern as `self_install`/`config.env`).
- `cloudflared` runs with `--token-file` (not `--token`), so the
  Tunnel Token never appears in `ps`/`/proc/<pid>/cmdline`.
- See TEST_REPORT.md → "Cloudflare Public SSH" for the specific tests
  (fake-curl API-helper tests, secret-leak greps, PID-identity tests,
  failure-isolation tests) and their results.

## v2.2.1 — Final release audit

Scope: final pre-release audit. Read the actual current code fresh
(not assumed from memory), fixed only real, important bugs found, made
no menu/architecture changes, and produced the release ZIP.

### Fixed
- **`self_install()` was not atomic.** It wrote the persistent manager
  to `/usr/local/lib/dx-nest/install.sh` with a direct in-place `cp -f`.
  A failure partway through (disk full, permission revoked mid-run, or
  a genuinely invalid source file) could leave a truncated or invalid
  file at that path — a real "partial installation" risk, explicitly
  the kind of failure this audit was asked to check for. Fixed with a
  temp-file-in-the-same-directory → `bash -n` validation → atomic
  `mv` pattern (both for the manager file and the `dx` wrapper). Now
  either the install fully succeeds, or any previous working
  installation is left completely untouched — verified directly by
  forcing a syntactically-broken source into `self_install()` and
  confirming the installed copy's checksum never changed.

### Verified unchanged (re-audited, not modified)
Read `install.sh` and `bootstrap.sh` fresh, line by line, rather than
assuming the v2.2 description was accurate, and confirmed all of the
following are still correct and intact: the secure config parser (no
`source`/`eval`, malicious `config.env` with `$(...)`, backticks, and
`;` all neutralized), PID identity checking (rejects a reused/unrelated
PID, including a live-but-unrelated process), `port_open`, disk-marker
reconciliation, the restart lock/impl split with full verification,
the Enter VPS recovery menu, dedicated `known_hosts` (grepped — no
code path ever touches the user's own `~/.ssh`), KVM/TCG detection,
network diagnostics, log rotation, `AUTH_MODE`/`VM_USER` config,
CLI mode and its exit codes, and the `set -e`/pipefail guards
(including the specific `status_vm` fix from v2.2 — re-reproduced
against stubbed `qemu-img`+`ps` failures and confirmed still safe).
A stray leftover test directory from earlier development sessions was
found and removed before packaging (never part of the source files,
just local working-directory residue).

### Not changed
- No new features. No menu restructuring. No new dependencies. No
  systemd/Docker/daemon/proxy. Same as every prior phase.

## v2.2 — Real-world Daytona fixes + persistent `dx` command

Scope: problems actually observed running on Daytona, plus critical
usability/recovery items. No unrelated features added (no Docker, no
systemd service, no daemon/supervisor — see README limitations).

### Fixed (confirmed real failure)
- **`status_vm` crash on `qemu-img`/`ps` failure**: the exact reported
  failure (`Unexpected failure at line 470 (command: head -n1)`) was a
  bare `var=$(pipeline)` assignment (`disk_sz=$(qemu-img info ... | awk
  ... | head -n1)`, and similarly `uptime_s=$(ps ... | tr ...)`). Under
  `set -Eeuo pipefail`, if `qemu-img info` fails — which happens for a
  real, common reason: the qcow2 is locked while QEMU has it open, i.e.
  exactly while the VM is RUNNING — pipefail makes the whole pipeline's
  exit status non-zero, and because these were bare assignment
  statements (not inside an if/while), that tripped `set -e` and killed
  the entire interactive menu. Reproduced the exact failure mode in
  testing (stubbed `qemu-img`/`ps` both failing while `is_vm_running`
  reports true) and confirmed the fix survives it, showing `UNKNOWN`
  instead of crashing. All disk-size/uptime/accel reads in `status_vm`
  now use the `var=$(...) || var=default` idiom. `head -n1` was also
  replaced everywhere with a single `awk '{...; exit}'` (no pipe stage
  that can independently fail on "no match", unlike `grep | head`).
- **Sandbox RAM/CPU `UNKNOWN` vs `0G/0 vCPU`**: when not configured,
  Status and VPS Config now show `UNKNOWN` instead of the misleading
  `0G / 0 vCPU`. `check_resource_safety` already skipped enforcement in
  this case (verified unchanged); it now also prints a one-time
  `[INFO]`/`[WARN]` explaining the check is informational-only until
  Sandbox RAM/CPU are set.
- **Every other `qemu-img info`/`ps`/`cat` read used for display**
  (disk-marker reconciliation, PID display, uptime, accel marker) was
  audited and put behind the same safe idiom — informational reads can
  now never take the manager down. Lifecycle-critical failures (QEMU
  won't start, port collision, lock not acquired, invalid config) are
  unchanged and still fail loudly and correctly.

### Added — persistent `dx` command
- **Self-install**: `install.sh` now copies itself to
  `/usr/local/lib/dx-nest/install.sh` and creates `/usr/local/bin/dx`
  (a 2-line wrapper) the first time it runs from a real file. This is
  completely separate from `BASE_DIR` (the VM/disk/config) — installing
  or repairing `dx` never touches an existing VM, confirmed by testing
  (byte-identical qcow2/seed.img after re-running the installer).
  Idempotent: running it again from the already-installed location is
  a silent no-op; running it from anywhere else re-syncs the persistent
  copy. Uses `$SUDO_CMD` (same pattern as the rest of the script) so it
  works whether invoked as root or via sudo; if it can't get write
  access to `/usr/local`, it warns clearly and the menu still works
  normally (a missing `dx` shortcut never blocks VM management).
- **`dx` works from any directory**: verified from `/`, `/tmp`, and
  `/root` in this environment — every path in the script is absolute
  (`BASE_DIR`, `INSTALL_LIB_DIR`, etc.), nothing depends on cwd.
- **`dx` needs no internet after installation**: `dx status`/`dx
  enter`/the interactive menu never call curl/wget — only the initial
  Ubuntu image download and `apt` dependency install do, and those are
  already isolated to VM-creation code paths. Verified in this sandbox,
  which itself has no network access at all.
- **Self-repair**: deleting `/usr/local/bin/dx` and running `dx install`
  (or Maintenance → "Repair/verify 'dx' command") recreates it — no
  download, no VM change. Verified by deleting the wrapper and
  confirming `command -v dx` fails, then succeeds again after repair.
- **`bootstrap.sh`** (new file): a separate, tiny script for the
  "GitHub is blocked in this network" case. Tries the primary GitHub
  URL, then a jsdelivr CDN mirror fallback, or a source given via
  `DXNEST_INSTALL_URL`/`DXNEST_SOURCE_URL` — HTTPS only, rejects any
  `http://` override. Downloads to a real temp file (never a process
  substitution, which has no stable path for `install.sh`'s own
  self-install step to copy from), validates it with `bash -n` before
  ever executing it, and reports the specific failure reason (DNS,
  timeout, TLS, empty response, syntax) per source tried. Verified: an
  unreachable override URL fails cleanly with "DNS resolution failed"
  and exit code 1; a non-HTTPS override is rejected outright; a
  syntactically-invalid downloaded file is rejected by the `bash -n`
  gate before being run.
- **`dx install` CLI command** and **Maintenance → "Repair/verify 'dx'
  command"** both call the same self-install/report logic.
- Installation verification report (`self_install_report`) checks: the
  persistent manager file, the `dx` command and its executability, the
  config/SSH directories, every dependency command DX-NEST actually
  uses, and `bash -n` on the installed copy.

### Not changed
- Existing menu structure (`[1]`..`[9]`, `[0]`), QEMU lifecycle, secure
  config parser, PID identity check, `port_open`, disk-marker
  reconciliation, restart lock/impl split + verification, Enter VPS
  recovery menu, dedicated known_hosts, KVM/TCG detection, network
  diagnostics, log rotation, AUTH_MODE/VM_USER config, CLI mode, and
  the `set -e` lifecycle guards from v2.1 are all unchanged — only
  extended with the fixes above. Maintenance gained one new numbered
  option; nothing was removed or renumbered.
- No systemd service, daemon, supervisor, Docker, database, or public
  tunnel was added, per explicit instruction.

## v2.1 — Production hardening pass

(See below — unchanged from the previous release notes.)


Scope: the 11 confirmed problems from the audit, plus the cross-cutting
requirements needed to make them actually work (locking discipline, PID
identity, socket validation, no destructive auto-recovery, honest error
reporting, accurate status). No menu structure, feature, or existing
working behavior was removed.

### Fixed
- **P0-1 — `restart_vm`**: rewritten to a fully verified flow (stop →
  verify stopped → start → verify QEMU running → wait for SSH → verify
  SSH auth). No longer reports success if SSH never comes up. Lock is
  acquired exactly once for the whole operation via new `_start_vm_impl`
  / `_stop_vm_impl` internal functions that take no lock themselves —
  `start_vm`/`stop_vm`/`restart_vm` are the only public, lock-taking
  entry points, so restart never nests `flock()` in the same process.
- **P0-2 — `config.env` loading**: no longer `source`d. Replaced with a
  strict line-by-line `KEY=VALUE` parser against a fixed whitelist
  (`VM_RAM_GB`, `VM_CPU`, `VM_DISK_GB`, `VM_USER`, `HOST_SSH_PORT`,
  `SANDBOX_RAM_GB`, `SANDBOX_CPU`, `AUTH_MODE`). Every value is then
  range/format-validated (`validate_config`), with bad values reset to
  safe defaults and a clear warning — never silently accepted, never
  executed as code.
- **P0-3 — `enter_vps` recovery**: SSH failures now show a real recovery
  menu (Retry / Status / Logs / Console / Restart / Return) with a
  3-attempt budget and per-failure diagnostics, instead of a single
  warning and exit.
- **P0-4 — KVM/TCG detection**: `/dev/kvm` is probed before every boot;
  falls back to TCG with a clear warning instead of silently assuming
  KVM. Status shows which acceleration mode is actually active.
- **P1-1 — dedicated `known_hosts`**: `$BASE_DIR/ssh/known_hosts`
  (0700/0600) is used for every SSH call via `-o UserKnownHostsFile=...`.
  The user's own `~/.ssh/known_hosts` is never touched. A rebuilt/reset
  VM's stale entry is only removed as part of the already-confirmed
  "Full Reset" action (types `DELETE`), never silently.
- **P1-2 — `ssh`/`ssh-keygen` dependency**: now checked and installed
  (`openssh-client`) like every other dependency, then re-verified.
- **P1-3 — disk marker reconciliation**: `.disk_size_gb` is compared
  against the qcow2's actual virtual size on every status check and at
  creation time. Marker-missing is repaired from the real size instead
  of blindly resizing; marker-smaller-than-actual just updates the
  marker; marker-larger-than-actual (suspicious) only warns — nothing
  is ever resized or deleted automatically.
- **P1-4 — real network diagnostics**: SSH/Network menu now has host
  port test, guest SSH/DNS/Internet tests, and a full diagnostic that
  clearly separates the Sandbox/host layer from the guest layer.
- **P2-1 — log rotation**: both `dxnest.log` and `vm-boot.log` rotate
  at 2 MiB (configurable via `LOG_MAX_SIZE`/`LOG_ROTATIONS`), keeping 3
  old copies. No secrets are ever written to either log.
- **P2-2 — `AUTH_MODE`/`VM_USER` in VPS Config**: both are now editable
  from the menu, with real validation and an explicit warning that an
  existing VM is not modified automatically.
- **P2-3 — CLI mode**: `install.sh {status|start|stop|restart|enter|
  logs|console|network|config|help}` runs non-interactively with proper
  exit codes (0 success, non-zero failure), for scripting/automation. A
  bare `install.sh` on a non-TTY now fails fast with a clear message
  instead of hanging on a `read`.

### Also fixed (cross-cutting, required for the above to actually work)
- **PID reuse safety**: `is_vm_running` no longer trusts a bare PID. It
  cross-checks `/proc/<pid>/cmdline` for the exact QEMU binary *and*
  image path together, and `/proc/<pid>/exe` when readable, before
  calling anything "running". A PID file left over from a killed QEMU
  that got reused by an unrelated process is now correctly reported as
  stopped, not running.
- **`set -e` footgun in the menu**: in bash, a bare failing command as
  the only statement in a `case` branch (e.g. `2) start_vm; pause ;;`)
  triggers `set -e` and kills the *entire* interactive script — not
  just that branch. This was a real, reproducible bug (verified in
  testing, see test report) that would have silently defeated the new
  restart/enter-recovery logic, since the script would exit before ever
  reaching the recovery menu. Every menu call to `start_vm`/`stop_vm`/
  `restart_vm`/`enter_vps` is now guarded with `|| true` at the call
  site; the functions still report and log their own errors.
- **`port_open`**: simplified to avoid closing a file descriptor in the
  parent shell that was only ever opened inside a subshell (harmless in
  practice, but confusing and unnecessary).

### Not changed (out of scope for this pass)
- Cloud-init rebuild-on-config-change behavior, SHA256 pinning strategy,
  and the "Remove seed.img" flow are unchanged from v2.0 — they were not
  in the confirmed problem list for this pass.
- No "strict KVM required" mode was added (no config key requests it);
  the only supported behavior is automatic TCG fallback with a warning.
- Real host RAM/CPU auto-detection (`/proc/meminfo`, `nproc`) was added
  as a *supplementary* warning-only check inside `check_resource_safety`
  (KVM/TCG item explicitly asked for resource awareness), but is not a
  hard limit — VM_RAM_GB/VM_CPU are still whatever the user configures.
