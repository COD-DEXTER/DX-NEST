DX-NEST FINAL RELEASE AUDIT REPORT (v2.2.1)
=============================================

Environment note: this sandbox runs as root with a writable
/usr/local. Outbound network is policy-restricted (apt/deb mirrors and
most hosts return 403/blocked; DNS resolution of arbitrary hosts fails)
— close enough to a locked-down Daytona network to exercise the
dependency-install failure path realistically, but not enough to run a
real `apt-get install qemu-system-x86` or download the real Ubuntu
image. No QEMU/KVM is installed and none could be installed here.
Everything below was actually executed and checked, not inferred from
reading the code.

FIXED
-----
- `self_install()` used a direct in-place `cp -f` to write the
  persistent manager to `/usr/local/lib/dx-nest/install.sh` — not
  atomic. A failure partway (disk full, permission revoked mid-run, an
  invalid source file) could leave a truncated/broken file at that
  path. Replaced with: create a temp file in the same directory →
  `bash -n` validate it → `mv` (atomic rename) into place. Same
  pattern applied to the `/usr/local/bin/dx` wrapper. Verified directly
  by forcing a syntactically-broken file into `self_install()`'s source
  path and confirming the previously-installed copy's SHA-256 never
  changed (install refused, old copy fully intact, `bash -n` still
  passes on it afterwards).

No other real bugs were found in this pass. The code was re-read in
full (not assumed correct from prior summaries) against every item in
the audit list; everything else checked out on inspection and testing.

VERIFIED
--------
[PASS] Persistent `dx` works from any directory
       `dx status` run from `/`, `/tmp`, `/root`, and from a brand-new
       `bash -c '...'` subprocess (simulating a fresh terminal/session)
       — identical, correct output every time. `command -v dx` resolves
       to `/usr/local/bin/dx`; its content execs the absolute path
       `/usr/local/lib/dx-nest/install.sh` — confirmed by `cat`.

[PASS] `dx` needs no internet, no GitHub, no /tmp, no process
       substitution, no particular shell session
       Every test above ran with this sandbox's restricted network in
       effect and worked. The wrapper and manager are both real files
       at absolute paths; nothing in the status/start/stop code path
       calls curl/wget except the VM-creation/dependency-install steps,
       which are separate and expected to need network.

[PASS] Self-install / reinstall safety (VM state preservation)
       Created a fake qcow2, seed.img, SSH private key, known_hosts,
       and config.env with recognizable content, recorded SHA-256 for
       each, ran `dx install` (self-install/repair) three times in a
       row, and re-checked: qcow2, seed.img, SSH key, known_hosts, and
       config.env were all byte-identical (`sha256sum -c`: OK). Only
       `logs/dxnest.log` differed — expected and correct, since the
       tool legitimately appended its own operational log lines; the
       diff was confirmed to be pure appension, original content intact
       (not corruption).

[PASS] Partial-installation safety (the fix above, end to end)
       Established a known-good installed copy, then attempted to
       install a deliberately syntax-broken source over it via
       `self_install()` directly. Result: install refused
       ("Could not install the persistent manager... Any PREVIOUS
       installation there was left untouched"), and the installed
       file's SHA-256 was unchanged before/after — proven, not assumed.

[PASS] bootstrap.sh reliability
       - Non-HTTPS override (`DXNEST_INSTALL_URL=http://...`): rejected
         outright ("Skipping non-HTTPS source"), never fetched, exit 1.
       - Unreachable override host: correctly reported "DNS resolution
         failed" and exited 1 without running anything.
       - The `bash -n` gate: a deliberately corrupted file is rejected
         by `bash -n`, exactly the check bootstrap.sh runs on every
         downloaded file before ever executing it; a real install.sh
         passes the same gate. (An actual live GitHub + CDN-fallback
         fetch could not be exercised — this sandbox's network doesn't
         reach those hosts — see NOT TESTED.)

[PASS] Bootstrap vs. installed `dx` stay separate
       `dx status`/`start`/`stop`/`restart`/`enter`/`config`/`logs`/
       `network` never call curl/wget/bootstrap.sh — grepped and
       confirmed; only `install_dependencies` and `download_base_image`
       (both explicitly part of first-time VM creation) touch the
       network.

[PASS] `set -Eeuo pipefail` re-audit
       Re-read every `$(...)` command substitution in both files.
       Confirmed: (a) every bare `var=$(...)` that can legitimately
       fail (qemu-img info, ps, cat on a possibly-raced PID file, sums
       lookups) is guarded with `|| default`, and (b) substitutions
       embedded inside a larger command's arguments (e.g. inside
       `printf`/`echo` strings) were already safe by bash's own
       semantics (the enclosing command's exit status, not the
       substitution's, is what `set -e` inspects) and needed no change.
       Re-ran the exact real-world crash repro from v2.2 (stubbed
       `qemu-img` AND `ps` both failing while the VM is reported
       running) — `status_vm` still degrades to UNKNOWN and returns
       normally (exit 0).

[PASS] Status is always safe (all 4 required scenarios)
       - VM stopped -> `VM Status : STOPPED`
       - VM running (normal) -> full info displayed
       - `qemu-img info` failing -> `Disk : UNKNOWN`, menu stays open
       - `ps` failing -> no `Uptime` line shown, no crash
       - Sandbox RAM/CPU unset -> `Sandbox : UNKNOWN / UNKNOWN`, never
         `0G / 0 vCPU`
       All reproduced together in one test (both stubs failing at
       once) — single `status_vm` call, exit code 0.

[PASS] PID safety / stale PID / PID reuse
       - PID file pointing at this very test shell's own live PID (a
         real, running, but unrelated process): correctly NOT reported
         as our VM.
       - PID file pointing at a real, live, unrelated process (`sleep
         300 &`): correctly NOT identified as our QEMU (cmdline doesn't
         match `qemu-system-x86_64` + our exact image path) — `stop`
         logic in `_stop_vm_impl` only ever signals a PID after
         `is_vm_running` has already confirmed this same identity
         check, so an unrelated process is never targeted.

[PASS] SSH safety
       Grepped the whole file: the only appearances of `~/.ssh` are in
       a comment and a user-facing note explaining that DX-NEST does
       NOT use it; every real `ssh` invocation uses
       `-o UserKnownHostsFile="$KNOWN_HOSTS"` pointing at
       `$BASE_DIR/ssh/known_hosts`. `enter_vps`'s recovery menu (Retry/
       Status/Logs/Console/Restart/Return) reviewed again — unchanged
       from v2.1/v2.2, still present and correctly guarded against the
       `set -e` case-branch footgun (`|| true` at every call site).

[PASS] Restart safety
       Stubbed `_start_vm_impl`/`_stop_vm_impl`/`is_vm_running` to
       trace the call sequence: confirmed that when the VM is not
       running, `restart_vm` calls `_start_vm_impl` exactly once and
       NEVER calls `_stop_vm_impl` (no blind double-start). The full
       stop-verify-start-verify-SSH-verify sequence from v2.1/v2.2 was
       re-read and is unchanged.

[PASS] QEMU/qcow2 protection
       Re-confirmed via the checksum test above: install/repair never
       touches BASE_DIR contents. Grepped for `rm -rf` in both files —
       zero occurrences. All deletions are explicit `rm -f` with named
       files, and the only ones that touch the qcow2/seed (Maintenance
       "Full Reset") require typing `DELETE` first — unchanged from
       v2.1.

[PASS] Config parser (exact malicious payload from the task)
       config.env containing:
         FOO="$(touch /tmp/PWNED)"
         $(touch /tmp/PWNED2)
         ; touch /tmp/PWNED3
       Loaded via `load_config` (line-by-line regex parser, never
       `source`); afterwards `test ! -e /tmp/PWNED`, `/tmp/PWNED2`, and
       `/tmp/PWNED3` all confirmed true — nothing executed.

[PASS] CLI final smoke test
       `dx help`, `dx status`, `dx config` -> exit 0. `dx logs` (no
       boot log yet) and `dx network` (VM not running) -> exit 1, as
       they should. `dx stop` on a never-started VM -> clean idempotent
       success, exit 0. `dx start`/`dx restart` correctly attempted
       dependency installation, hit this sandbox's real network
       restriction, and failed cleanly with a clear `[ERROR]` message
       and exit 1 — no crash, no corrupted state, no duplicate process.

[PASS] No unnecessary dependencies / no scope creep
       Dependency list unchanged from v2.2 (bash, curl, awk, sed, grep,
       cat, ps, flock, timeout, ssh, ssh-keygen, qemu-system-x86_64,
       qemu-img, socat) — all of them are actually called somewhere in
       the file (grepped each). No Docker, systemd unit, daemon,
       external service, or proxy anywhere in either file.

[PASS] Permissions
       `config.env` 600, SSH private key 600, `known_hosts` 600, `ssh/`
       dir 700, `BASE_DIR` 750, installed manager and `dx` wrapper 755
       (no secrets in either — fine to be world-readable/executable).

[PASS] Shell portability
       `bash -n install.sh` and `bash -n bootstrap.sh` both clean.
       Both shebangs are `#!/bin/bash`. No non-POSIX-bash-only
       constructs used outside of bash itself (both files are written
       for and only claim to support bash, consistent with the
       shebang).

[PASS] Documentation consistency
       README/CHANGELOG both updated with this audit's actual change
       (the atomic self-install fix) and nothing else; no claims were
       added for anything not actually implemented.

[PASS] Final grep sweep
       `grep -RInE 'source |^\s*\.\s+|head -n|head -1|tail -n|rm -rf|
       mktemp|curl|wget|sudo|systemctl|service|nohup|eval ' .` — every
       hit reviewed individually. No `eval` anywhere. No `rm -rf`
       anywhere. The one `head -n1` match left is inside a code COMMENT
       explaining the historical bug, not real code. `systemctl`
       appears only inside the cloud-init YAML text written for the
       GUEST (enabling sshd inside the VM) — not a host-side systemd
       dependency. Every `sudo`/`curl`/`wget`/`mktemp` use was checked
       individually and is legitimate (see FIXED/VERIFIED above for the
       ones that mattered).

NOT TESTED
----------
[NOT TESTED] Requires real QEMU/Daytona environment
       Reason: this sandbox has no qemu-system-x86_64/KVM and its
       network policy blocks the apt mirrors needed to install them
       (confirmed by an actual `dx start` attempt above, which failed
       cleanly at `apt-get update` with 403s — not faked). Specifically
       not exercised end-to-end: real VM boot, real SSH into the guest,
       a real `dx restart`/`dx enter` against a live QEMU process, a
       real live GitHub + CDN-fallback fetch in bootstrap.sh, and a
       real Daytona Sandbox restart/pause/archive cycle. The logic each
       of these depends on (lock discipline, PID identity, restart
       verification sequence, recovery menu, bootstrap source fallback
       and validation) was reviewed and unit-tested in isolation as
       described above, but the full real-hardware path needs an actual
       Daytona sandbox with outbound access to Ubuntu's mirrors.

RELEASE
-------
See the bottom of this report / the final chat response for the ZIP
path and SHA-256.


DX-NEST PHASE 2 REPORT (previous phase, for history)
=====================================================
=======================

Environment note: this sandbox has root access and a writable
/usr/local, but NO network access at all and no real QEMU/KVM/Daytona.
That means every "no internet needed" claim below was incidentally
proven by the environment itself (nothing could have silently used the
network even if the code had tried to). Anything needing a real QEMU
boot or a real Daytona sandbox is marked [NOT TESTED] with the reason.

[PASS] head/qemu-img failure fixed
       — Reproduced the EXACT reported failure conditions: stubbed
         `qemu-img info` to fail (simulating "image locked by the
         running VM") AND stubbed `ps -o ...` to fail simultaneously,
         with `is_vm_running` forced true. Called `status_vm` directly.
         Result: printed `Disk : UNKNOWN`, `Accel : UNKNOWN`, no
         `Uptime` line — and returned normally (exit 0). The old code
         would have hit `set -e`+pipefail and killed the whole process
         at this exact point; confirmed by re-testing the underlying
         `set -e` + bare-pipeline-assignment mechanism in isolation.

[PASS] status survives qemu-img failure
       — Same test as above; `get_disk_size_display()` degrades to
         "UNKNOWN" and logs a WARN line instead of raising.

[PASS] Sandbox UNKNOWN resources handled correctly
       — With SANDBOX_RAM_GB=0/SANDBOX_CPU=0 (default/unset), status_vm
         printed `Sandbox : UNKNOWN / UNKNOWN`, never `0G / 0 vCPU`.
         `check_resource_safety`'s existing `!= "0"` guard (confirmed
         present and unchanged) means it never false-rejects on unset
         Sandbox values; it now also prints an informational note once.

[PASS] required dependency detection
       — `self_install_report` (and `install_dependencies`) enumerate
         exactly the command list from the task (bash, curl, awk, sed,
         grep, cat, ps, flock, timeout, ssh, ssh-keygen,
         qemu-system-x86_64, qemu-img, socat) and report each as
         available/missing. Verified output in this environment
         correctly flagged ssh, ssh-keygen, qemu-system-x86_64,
         qemu-img, and socat as missing (none are installed here) and
         everything else as present.

[PASS] persistent installation
       — Ran install.sh from a real temp file (`/tmp/dxnest-boot-
         test.sh`, simulating what bootstrap.sh hands off to) with the
         `install` CLI command. Verified afterwards:
           /usr/local/lib/dx-nest/install.sh exists, mode 755
           /usr/local/bin/dx exists, mode 755, execs the path above

[PASS] /usr/local/bin/dx
       — `command -v dx` resolved to `/usr/local/bin/dx` from a fresh
         bash process.

[PASS] dx works from /
       — `cd / && dx status` — worked, printed status.

[PASS] dx works from arbitrary directories
       — Also verified from `/tmp` and `/root`; identical output
         regardless of cwd (confirms no relative-path dependency).

[PASS] dx works after "sudo su" / new shell (terminal-disconnect sim)
       — Ran `dx status` from a brand-new `bash -c '...'` subprocess
         (no shared state with the process that did the install),
         simulating a disconnected terminal + new session as root.
         Worked identically.

[PASS] dx works without internet after installation
       — This entire sandbox has zero network access throughout this
         session (confirmed: bootstrap.sh's own unreachable-host test
         below got "DNS resolution failed" against a real DNS lookup
         attempt). Every `dx status`/`dx install` call above ran
         successfully under those conditions.

[PASS] GitHub fallback (source list + validation logic)
       — Verified the bash -n gate: a deliberately corrupted script
         (`this is not valid bash {{{ ((`) is correctly rejected by
         `bash -n`, exactly the check bootstrap.sh runs before ever
         executing a download; the real install.sh passes the same
         gate. Could not test an actual live fallback CDN fetch (no
         network in this sandbox) — see NOT TESTED below.

[PASS] source override
       — `DXNEST_INSTALL_URL=https://this-host-does-not-exist....` :
         bootstrap.sh correctly reported "DNS resolution failed" and
         exited 1. `DXNEST_INSTALL_URL=http://...` (non-HTTPS): rejected
         outright with "Skipping non-HTTPS source", exited 1. Neither
         run touched or executed anything.

[PASS] installer syntax validation
       — `bash -n` on both install.sh and bootstrap.sh: clean. The
         bad-syntax-rejection gate itself verified as above.

[PASS] existing VM preserved
       — Placed sentinel files at `ubuntu-22.04-base.qcow2` and
         `seed.img` inside BASE_DIR, recorded their md5sums, re-ran the
         installer (`install` CLI command, simulating "installer run
         again"), and confirmed both files are byte-identical
         afterwards (`md5sum -c` — both OK). Self-install never reads
         or writes anything under BASE_DIR.

[PASS] existing qcow2 preserved
       — Same test as above (qcow2 sentinel included).

[PASS] CLI exit codes
       — `dx help`/`dx status`/`dx config` → exit 0. `dx bogus-command`
         → exit 2. Unreachable/non-HTTPS bootstrap sources → exit 1.
         (Full start/stop/restart/enter exit-code behavior already
         covered in the v2.1 report and unchanged here.)

[PASS] set -e behavior
       — Re-ran the full v2.1 regression suite after all Phase 2 edits
         (config validation, malicious config, PID reuse, the
         `case`-branch `set -e` footgun + its `|| true` fix, CLI
         dispatch, no-TTY guard) — all still pass unchanged. Re-verified
         the specific status_vm crash is fixed (see first item above).

[PASS] informational failures are non-fatal
       — Audited every remaining bare `var=$(...)` command substitution
         in the file after the fixes; the only ones left are either (a)
         embedded inside a larger command's arguments (e.g. inside a
         `printf`/`echo` string), which per bash semantics don't affect
         that command's own exit status and were already safe, or (b)
         explicitly guarded with `|| default`. Lifecycle-critical paths
         (QEMU launch, port collision, lock acquisition, disk resize at
         creation) were left as real, intentional failures — unchanged.

E2E:
[NOT TESTED] Fresh install (real bootstrap.sh -> real GitHub fetch)
       Reason: no network access in this environment. The download/
       validation logic was verified with local stand-ins (temp file,
       bad-syntax file, unreachable-host override) instead.
[NOT TESTED] Start / Stop / Restart / Enter VPS (real QEMU)
       Reason: no qemu-system-x86_64/KVM in this environment (also true
       in the v2.1 report — unchanged).
[PASS] Terminal disconnect -> sudo su -> dx (the persistence/cwd/no-
       network parts of this scenario)
       Reason for partial scope: simulated via a fresh subprocess +
       different cwd + no network, which covers everything about this
       scenario EXCEPT a real running QEMU VM to reconnect to — status
       correctly showed STOPPED (no VM was ever created in this test,
       since QEMU isn't installed here).
[NOT TESTED] Daytona Sandbox restart
       Reason: no real Daytona sandbox available in this environment.
[NOT TESTED] GitHub blocked (real DNS-level block of github.com /
       raw.githubusercontent.com, with a real working fallback CDN)
       Reason: this sandbox already has no network at all, so it can't
       distinguish "GitHub specifically blocked" from "no network" or
       exercise a real successful fallback fetch. The failure-path
       logic (unreachable source -> clear reason -> try next -> all
       fail -> clear final error, never run anything unvalidated) was
       verified directly as described above.
[NOT TESTED] Internet unavailable after installation (dx still opens)
       Reason: technically this WAS exercised throughout this entire
       session (zero network access throughout), but there was no
       previously-existing "internet was available, then went away"
       transition to test since the environment never had it. Marking
       NOT TESTED for the specific before/after transition scenario;
       the "no internet needed" property itself is covered by [PASS]
       dx works without internet above.

Honesty note
------------
Every PASS above was produced by actually running the described
command in this sandbox and checking its output/exit code/file state —
not inferred from reading the code. Every NOT TESTED is something that
specifically requires real QEMU, real KVM, a real Daytona sandbox, or a
real external network boundary, none of which exist in this review
environment. Please run the E2E NOT TESTED items once inside an actual
Daytona sandbox before considering this phase fully closed — in
particular a real `bash <(curl ... bootstrap.sh)` from a clean sandbox,
and the full Start -> Enter -> disconnect -> reconnect loop against a
real running VM.


DX-NEST v2.1 TEST REPORT (previous phase, for history)
=======================================================
========================

Environment note: this sandbox has no network access and no QEMU/KVM
installed, so anything requiring a real download, a real boot, or a
real Daytona sandbox is marked [NOT TESTED] below with the reason —
not faked as PASS. Everything else was actually executed (`bash -n`,
isolated function sourcing via `DXNEST_TEST_MODE=1`, and stubbed
`qemu-img`), not just read by eye.

Static checks
-------------
[PASS] `bash -n install.sh` — no syntax errors (1386 lines)
[PASS] Menu structure, options 0-9, and all previously-working features
       preserved (nothing removed)

Per-item verification
----------------------
[PASS] P0-1 restart verification
       — Traced the lock-acquisition path: start_vm/stop_vm/restart_vm
         are the only functions that take LIFECYCLE_LOCK; _start_vm_impl/
         _stop_vm_impl take none. Ran restart_vm with stubbed impls and a
         10s outer `timeout` — completed immediately, no deadlock.
       — Confirmed restart_vm's failure path (fake "QEMU did not stay up")
         reports [ERROR] with PID/log pointers instead of a fake success.
[NOT TESTED] Real restart against a real running QEMU VM + real SSH
       Reason: no qemu-system-x86_64/KVM/network in this environment.

[PASS] P0-2 config validation
       — Fed a config.env with `VM_CPU=abc`, `VM_RAM_GB=999999`,
         `HOST_SSH_PORT=99999`, `VM_USER=test user`, `AUTH_MODE=whatever`,
         an unknown key, a malformed line, and a line attempting command
         substitution (`EVIL=$(touch /tmp/PWNED_$$)`).
       — Result: every bad value was reset to its default with a clear
         warning; the unknown key and malformed line were ignored with a
         warning; `/tmp/PWNED_*` was never created — confirms config.env
         is parsed as data, never executed as shell.

[PASS] P0-3 Enter VPS recovery
       — Code path reviewed: 3-attempt budget, diagnose_vm_connectivity
         before each recovery menu, Retry/Status/Logs/Console/Restart/
         Return all present and each wired to a real action.
[NOT TESTED] Live interactive recovery menu against a real failing SSH
       Reason: requires a real QEMU boot to reach a genuine "SSH not
       ready yet" state; the branching logic itself was verified by code
       review + the isolated diagnose_vm_connectivity function running
       cleanly against a stopped/nonexistent VM.

[PASS] P0-4 KVM/TCG detection
       — probe_kvm() correctly reported "TCG" in this environment (no
         /dev/kvm present); status_vm and compute_accel both reflect it.

[PASS] P1-1 dedicated known_hosts
       — ssh_opts() builds `-o UserKnownHostsFile=$KNOWN_HOSTS` pointing
         under BASE_DIR/ssh, confirmed never referencing $HOME/.ssh
         anywhere in the file (grepped for `.ssh/known_hosts` outside
         SSH_DIR — none found).

[PASS] P1-2 openssh-client dependency
       — install_dependencies() dependency list and apt package list
         both include ssh/ssh-keygen and openssh-client; post-install
         re-verification loop includes both commands.

[PASS] P1-3 disk marker reconciliation
       — Tested all 4 scenarios against a stubbed qemu-img reporting a
         20G virtual disk:
         marker missing      -> recorded 20G, no resize call made
         marker == actual    -> no-op
         marker (15) < actual (20) -> marker updated to 20, no resize
         marker (25) > actual (20) -> WARN only, marker left at 25,
                                       disk untouched
         All four matched the spec exactly.

[PASS] P1-4 network diagnostics
       — Code review: host-port test, guest SSH/DNS/Internet tests, and
         "Full network diagnostic" all present in the SSH/Network menu,
         each clearly labeled under a Host/Sandbox vs Guest heading.
[NOT TESTED] Actual guest DNS/Internet PASS/FAIL against a live guest
       Reason: no running guest in this environment.

[PASS] P2-1 log rotation
       — With LOG_MAX_SIZE=500 (bytes, for a fast test) and 200 log
         lines written, dxnest.log rotated correctly into .1/.2/.3 and
         stayed capped at LOG_ROTATIONS=3, with the live file staying
         small. No credentials pass through log_line() anywhere in the
         file (grepped for VM_PASSWORD near any log_line/info/warn/err
         call — none found).

[PASS] P2-2 AUTH_MODE / VM_USER configuration
       — Code review: both new options present in vps_config_menu,
         VM_USER validated with the same regex as validate_config()
         (and rejects "root"), AUTH_MODE restricted to key/password,
         both warn when a VPS already exists (seed.img present).

[PASS] P2-3 CLI mode
       — `./install.sh help` -> usage text, exit 0
       — `./install.sh bogus-command` -> "Unknown command", exit 2
       — `./install.sh status` (no VM created) -> STOPPED status, exit 0
       — `./install.sh config` -> prints current effective config, exit 0
       — `echo | ./install.sh < /dev/null` (no TTY, no args) -> clear
         "Interactive terminal required" message + usage, exit 1,
         instead of hanging on `read`.
[NOT TESTED] `start`/`stop`/`restart`/`enter`/`console`/`network` CLI
       subcommands against a real VM
       Reason: require a real QEMU boot.

Cross-cutting fixes
--------------------
[PASS] PID reuse safety
       — is_vm_running() correctly rejected: (a) a PID file pointing at
         this very shell's own PID (a real, live, but unrelated
         process), (b) a PID file containing garbage text, (c) a missing
         PID file. Verified the cmdline-matching logic directly against
         a synthetic "qemu-system-x86_64 ... $IMAGE_PATH ..." string.
[PASS] `set -e` footgun (bare failing command in a `case` branch kills
       the whole interactive script under `set -Eeuo pipefail`)
       — Reproduced the bug in isolation: a case branch calling a
         failing function with no guard aborted the entire script
         before the following line ever ran. Confirmed the `|| true`
         guard used at every menu call site (start_vm/stop_vm/
         restart_vm/enter_vps) fixes it cleanly — this was necessary
         for P0-1/P0-3's recovery logic to be reachable at all, so it's
         called out explicitly even though it wasn't in the original
         11-item list.
[NOT TESTED] Concurrent execution (`./install.sh start` from two
       terminals at once), stale monitor/console socket handling under
       a real QEMU crash, QEMU crash recovery, port collision against a
       real listener, Daytona sandbox restart/recovery
       Reason: all require either a real running QEMU process, a real
       Daytona sandbox, or true multi-process concurrency that this
       single sandboxed review environment can't exercise. The relevant
       code (flock-based single lock acquisition, is_vm_running's
       stale-PID handling, port_open() pre-boot check) was reviewed and
       unit-tested in isolation as noted above, but not exercised
       end-to-end against a live VM.

Documentation
-------------
[PASS] README.md updated: explicit "no public IP" section, the 4-layer
       lifecycle diagram (Daytona Sandbox ≠ DX-NEST ≠ QEMU ≠ Guest), and
       a v2.1 summary of what changed.
[PASS] CHANGELOG.md added.

Honesty note
------------
Nothing above was marked PASS without either running it in this
sandbox or tracing the exact code path by hand; anything needing a real
QEMU boot, real KVM, real network, real Daytona sandbox lifecycle, or
true OS-level concurrency is marked NOT TESTED with the specific reason,
per your instructions. Please smoke-test the [NOT TESTED] items once
this runs inside an actual Daytona sandbox — in particular the full
Fresh-install → Start → Enter path end-to-end.

==========================================================
v2.3.0 — Cloudflare Public SSH
==========================================================
This sandbox's bash_tool has no outbound network access at all (not
just a Daytona restriction — this specific review environment). Every
test below that needed to "call Cloudflare" used a scripted fake
`curl` shim on PATH that returns canned JSON for the exact endpoints
install.sh calls, so the *bash logic* (parsing, control flow, error
handling, idempotency) is genuinely exercised — this is NOT the same
as a real Cloudflare connectivity test, and is never represented as one.

Config layer
------------
[PASS] `CLOUDFLARE_ACCOUNT_ID` / `CLOUDFLARE_TUNNEL_ID` load from
       config.env only via the CONFIG_KEYS whitelist; an injected
       unrecognized key (`EVIL_TOKEN_INJECT=hacked`) is warned about
       and ignored, never trusted — same test pattern as the original
       config-parser audit.
[PASS] `validate_config` clears a malformed `CLOUDFLARE_SSH_HOST`
       ("not a valid host!!" -> "") and a malformed
       `REMOTE_ACCESS_PROVIDER` ("evilprovider" -> ""), never aborts.
[PASS] `dx config` prints `CLOUDFLARE_ACCOUNT_ID`/`CLOUDFLARE_TUNNEL_ID`
       but never the API Token or Tunnel Token content — verified with
       a real (fake) token value planted in both files and grepped for
       in the command's actual stdout.

Cloudflare API helper logic (fake-curl)
----------------------------------------
[PASS] `_cf_json_field` / `_cf_json_bool` extract from a flattened
       JSON string correctly (including the `-oE` fix needed for the
       `(true|false)` alternation — the first version used plain
       `grep -o`, which is POSIX BRE and treats `()` literally; this
       was caught by the test, not by inspection).
[PASS] `cf_discover_account`: single-account response -> auto-selects
       `CLOUDFLARE_ACCOUNT_ID` with no prompt.
[PASS] `cf_find_or_create_tunnel` — three scenarios, all correct:
       (1) no existing tunnel -> creates one, records the returned ID;
       (2) `CLOUDFLARE_TUNNEL_ID` already set and the tunnel is still
       alive (`deleted_at` empty) -> reused, zero create-call side
       effects; (3) recorded tunnel was deleted server-side
       (`deleted_at` set) -> falls back to a name lookup
       (`dx-nest-<hostname>`) and reuses the one found there instead of
       creating a duplicate. This is the literal idempotency/duplicate-
       prevention requirement — reproduced end-to-end, not assumed.
[PASS] `cf_configure_route` PUTs the ingress config and reports the
       exact hostname -> `ssh://localhost:2222` mapping on success.
[PASS] `cf_get_tunnel_token`: retrieves the token, writes it to
       `CF_TOKEN_FILE` with `0600`, and — checked explicitly — the raw
       token string never appears in the function's own stdout/stderr,
       only inside the file.
[PASS] `cf_try_create_dns_record`: succeeds when the fake zone lookup
       resolves; the code path that falls back to a manual-DNS warning
       on API/permission failure was code-reviewed (not separately
       exercised in this pass — see NOT TESTED below).

Secret handling / repair
-------------------------
[PASS] API Token file and Tunnel Token file both end up `0600`
       (`stat -c %a`), including after `remote_repair` (which
       explicitly re-chmods both).
[PASS] `remote_repair` re-fetches a missing/empty Tunnel Token
       automatically when the API Token + `CLOUDFLARE_TUNNEL_ID` are
       still on file — verified by deleting `CF_TOKEN_FILE` and
       confirming Repair restored it via the fake `cf_get_tunnel_token`
       path, without asking the user to re-run Setup.
[PASS] Full grep audit of the final install.sh for: `X-Auth-Email`,
       `X-Auth-Key`, "global api key" (case-insensitive), "oauth"
       (case-insensitive) — the only "oauth"/"Global API Key" matches
       are this feature's own `info` line explaining that neither is
       used; no functional code references either.
[PASS] Grep audit: `CF_API_TOKEN_FILE` / `api_tok` only ever appear
       next to file-permission/creation calls or inside the one
       `Authorization: Bearer` header construction in `cf_api()` —
       never in an `echo`/log/status context.
[PASS] `remote_status` / `remote_connection_info` source reviewed and
       grepped: neither ever `cat`s `CF_TOKEN_FILE` or
       `CF_API_TOKEN_FILE`.
[PASS] End-to-end leak check: planted a distinctive fake token value in
       both files, ran the full start/stop/repair/status cycle, and
       grepped stdout, stderr, and `cloudflared.log` — the value never
       appeared anywhere except inside the two 0600 token files
       themselves.

Regression (existing DX-NEST behavior)
----------------------------------------
[PASS] `dx status`, `dx config`, `dx help`, `dx logs` (exits 1 with
       "No boot log yet" on a fresh install — correct, not a
       regression) all still work after every change in this release.
[PASS] Full Remote Access lifecycle (start -> status -> repair ->
       stop) re-run after the v2.3.0 API-token rewrite with the same
       PID-identity tests as the original module: nonexistent PID
       rejected, unrelated real process rejected (PID-reuse
       protection), our own (fake, compiled) cloudflared process
       correctly identified and cleanly, verifiably terminated on stop
       — not a blind `kill $(cat pidfile)`.
[PASS] `bash -n install.sh` clean at every step of this release (it
       would have caught the `_cf_json_bool` regex bug's *syntax*, but
       that bug was a logic error, not a syntax error — this is why
       the functional fake-curl tests above matter and `bash -n` alone
       was never treated as sufficient).
[NOT TESTED] ShellCheck — not available in this sandbox
       (`command -v shellcheck` -> not found). Not run; not faked as
       passing.

NOT TESTED (needs a real Cloudflare account/network)
-------------------------------------------------------
Real Cloudflare integration:
NOT RUN — this test environment has no usable external network access
at all (not just a Daytona restriction — `bash_tool` here has network
disabled). The fake-curl tests above are genuine local tests of
install.sh's own logic, but they are not, and are not claimed to be,
equivalent to a real Cloudflare API call, real DNS propagation, real
`cloudflared` connecting to Cloudflare's edge, or a real SSH connection
through the finished tunnel. Also not exercised for the same reason:
`install_cloudflared`'s actual apt-repository install path (only its
failure-safety when `curl`/`apt-get` are unreachable), multiple-account
`cf_discover_account` prompt path, and `cf_try_create_dns_record`'s
permission-denied fallback branch. Please run Setup against a real
Cloudflare account once this is inside an actual Daytona sandbox with
outbound network access, before relying on it for production traffic.

