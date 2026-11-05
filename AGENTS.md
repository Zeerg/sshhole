# AGENTS.md — sshhole research PoC

Local, throwaway Docker reproduction of the OpenSSH/musl `*` shadow-field
password bypass from https://sshhole.com. Defensive research only — never
point this at systems you don't own.

## Commands

| task | command |
|---|---|
| build lab image | `docker build -t sshhole lab/` |
| full demo (vuln) | `./poc.sh` |
| demo vs patched | `./poc.sh 10.6p2` |
| assertion matrix | `./test.sh` or `./test.sh 10.6p2` |
| PAM control | `./test.sh 10.6p1-pam` |
| PAM disabled control | `./test.sh 10.6p1-pam-off` |
| teardown | `docker rm -f sshhole` |

Image and container are both named `sshhole`; sshd listens on `2222`.
`poc.sh`/`test.sh` build the image (using Docker's cache after the first run)
and start the requested sshd build themselves.
macOS + colima (arm64) works fine — builds are native Alpine arm64.

## Layout

- `lab/Dockerfile` — Alpine 3.21; builds non-PAM OpenSSH 10.6p1 and 10.6p2,
  plus a 10.6p1 PAM control; creates test accounts
- `lab/sshd_config` — `PasswordAuthentication yes`, `PermitRootLogin yes`
  (lab-only), `PerSourcePenalties no`
- `poc.sh` — self-contained demo with the complete `ssh` invocation
- `test.sh` — strict vulnerable/fixed assertion matrix
- `primitives/crypt-poc.c` — standalone musl `crypt()` primitive check
- `research/docker-images.md` — image exposure survey + cloud-image source chain
- `research/musl-platforms.md` — OpenWrt and musl distribution assessment

## Accounts in the lab (shadow fields)

`alice` → `$6$` real hash (pw: `correct horse battery staple`) — the
salt donor · `victim` → `*` · `alpine` → `*` + wheel + `doas nopass`
(models affected Alpine tiny-cloud images) · `root` → `*` · `sshd` → `!`
(privsep).

## Hard-won facts — read before touching the exploit path

- **Two prompts, one connection.** The bypass only fires on prompt ≥2 of a
  single SSH connection. `pick_salt()` caches its salt in a static buffer
  in the per-connection monitor process; prompt 1 primes the cache but its
  `getspnam`/`explicit_bzero` clobbers the musl `spwd` buffer that
  `pw_password` points into → `strcmp` fails. Prompt 2 hits the cache, no
  scan, `"*"` survives. Separate connections never share the cache.
- **`sshpass` cannot trigger it** — feeds the first prompt then drops. Use
  `SSH_ASKPASS_REQUIRE=force` + `NumberOfPasswordPrompts`, as shown directly
  in `poc.sh`.
- **`PerSourcePenalties`** (default-on in OpenSSH 10.x) drops repeat-offender
  source IPs after a few failures. Disabled in `lab/sshd_config` so the
  matrix can run; re-enabling it will make repeated tests look "patched".
- **`!` ≠ `*`.** Alpine's normal lock marker `!` does not trigger the bug;
  only a literal `*` shadow field does. Don't "simplify" accounts to `!`.
- **musl only.** glibc `crypt()` has no 256-byte cap and returns real
  hashes — the repro silently passes-as-denied on glibc.
- `--without-pam` matters: effective `UsePAM yes` routes password checks away
  from the vulnerable path. `./test.sh 10.6p1-pam` verifies this control.
- `passwd -d`/empty fields are a different state than `*` — `corpusops/sshd`
  "fixes" its `root:*` that way at boot.
- OpenSSH's `make install` creates the `sshd` privsep user; the Dockerfile's
  `adduser sshd` is intentionally idempotent (`id || adduser`).

## Verification

`./poc.sh` must show a one-prompt denial followed by a two-prompt login to
`alpine` and a root shell through `doas`. `./poc.sh 10.6p2` must deny the
same two-prompt attempt. The full
`./test.sh` matrix also verifies the alpine/doas and root cases, negative
controls, and Alice's real password. Both versions are required for a valid
run.

## Conventions

- `poc.sh` and `test.sh` are bash. Keep their explicit SSH options aligned.
- Comments explain *why* (subtle auth mechanics), not what.
- Research docs live in `research/`; keep findings evidence-backed
  (source lines, `docker inspect`/exec output) — no vibe claims about
  third-party images.
