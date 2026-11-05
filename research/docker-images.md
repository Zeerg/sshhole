# Docker Hub survey: who ships a musl sshd + the right account mix?

Checked the top sshd/sftp/git-server images by pull count (Nov 2026). For the
bug to fire **by default** an image needs ALL of:

1. musl libc (Alpine family)
2. OpenSSH `sshd` built **without** PAM
3. `PasswordAuthentication yes`
4. some account whose `/etc/shadow` field is `*`
5. another account with a real `$` hash (gives `pick_salt()` a salt to borrow)
6. the `*` account must be password-permitted (i.e. not blocked by
   `PermitRootLogin prohibit-password/no` when it's root)

## Results

| image | pulls | libc | PAM | `*` accts | real-hash | pw auth | verdict |
|---|---|---|---|---|---|---|---|
| atmoz/sftp | 1.03B | glibc | yes | *all* | none | yes | safe — wrong libc |
| testcontainers/sshd | 35M | **musl** | no | none | root (`$6$`) | yes* | safe by default, **one `*` user away** |
| linuxserver/openssh-server | 30M | musl | no | none (all `!`) | none | **no** | safe — hardened |
| emberstack/sftp | 23M | glibc | yes | *all* | none | yes | safe — wrong libc |
| panubo/sshd | 8.8M | musl | no | none (all `!`) | none | yes | safe — no `*` target |
| writl/sftp | 2.3M | musl | no | **root** | `sftp` via `PASS=` env | **yes** | **near-miss**: `PermitRootLogin no` is the only thing saving it |
| netresearch/sftp | 943K | musl | no | none | none | yes | safe |
| linuxkit/sshd | 731K | musl | no | n/a (keys only) | n/a | **no** | safe — key-only image |
| walser/sshd | 554K | musl | no | none | none | **no** | safe |
| mulinbc/sshd | 389K | glibc | yes | sys accts | root | yes | safe — wrong libc |
| serversideup/docker-ssh | 96K | glibc | yes | *all* | none | yes | safe — wrong libc |
| rockstorm/git-server | low | musl | no | **root** | `git` | yes* | **near-miss**: `PermitRootLogin` default blocks root |
| corpusops/sshd | 12K | musl | no | root→`""` at boot | users via env | yes* | near-miss — `passwd -d root` empties the field |
| hermsi/alpine-sshd | low | musl | no | root | none | yes* | safe — no salt to borrow |
| sickp/alpine-sshd | low | musl | no | none | root | yes* | safe — no `*` target |
| jkarlos/git-server-docker | low | musl | no | none | `git` | **no** | safe |
| vimagick/openssh | low | musl | no | none | none | yes* | safe |
| bensuperpc/sshd | 109K | musl | no | none | none | yes* | safe |
| ddev/test-ssh-server | 135K | glibc | yes | *all* | none | **no** | safe |

`*` = no explicit `PasswordAuthentication` line → OpenSSH default `yes`.

## Bonus: the affected Alpine tiny-cloud image chain

Alpine's advisory identifies official tiny-cloud images from 3.18.11 through
3.24.3 with this account model. Both `tiny-cloud` (`lib/tiny-cloud/init`) and
the build repo's `scripts/setup` do:

```sh
: "${CLOUD_USER:=alpine}"                       # or IMAGE_LOGIN
adduser -h "/home/$user" -G "$user" -D "$user"
addgroup "$user" wheel
echo "$user:*" | chpasswd -e                    # → alpine:*
# + 'permit nopass :wheel' → doas.d/wheel.conf (or sudoers.d/wheel)
```

- `alpine` is **non-root** → `PermitRootLogin` is irrelevant
- passwordless `doas` → any `alpine` login is effectively uid 0
- root itself is `*`→locked (`scripts/setup` does `root:*` then `passwd -l`)
- the only missing link by default: `pick_salt()` needs *one* real-hash
  account to borrow a salt from — any password provisioned via
  cloud-config/user-data or any other hashed account completes the chain.

Images built from Alpine 3.21.10, 3.22.8, 3.23.8, and 3.24.4 include the
fixed package. See the [Alpine security advisory][alpine-advisory].

Reproduced in `lab/` as the `alpine` account: `ssh alpine@ + 300×A` (2nd
prompt) → `doas id` → `uid=0`.

## Takeaways

- **Nothing popular is vulnerable fully-by-default.** The `*`-+real-hash combo
  is what saves everyone; Debian/Ubuntu dominates the SFTP space anyway.
- The closest is **writl/sftp** (2.3M): musl + `root:*` + `PasswordAuthentication
  yes` + a real-hash `sftp` user when `PASS=` is set. Only `PermitRootLogin no`
  stands between it and instant uid-0.
- **testcontainers/sshd** (35M) already has `root:$6$…` — adding any `*` key-only
  test user (a common fixture pattern) makes it exploitable.
- The real exposed population isn't Hub images at all — it's
  - **custom `FROM alpine` + `apk add openssh` Dockerfiles** (bastions, git
    servers, backup targets) that create a `*` "key-only" account alongside a
    password account, and
  - **non-Docker musl targets**: Alpine AWS/Azure images (`alpine:*` + doas),
    optional OpenSSH on OpenWrt, and configuration-dependent Buildroot,
    Yocto, and Gentoo-musl builds. See
    [the platform assessment](musl-platforms.md).
- OpenWrt uses dropbear, not OpenSSH → unaffected.
- `PermitRootLogin` defaults (`prohibit-password`) are quietly doing a lot of
  work — they block every `root:*` case even when everything else lines up.

[alpine-advisory]: https://alpinelinux.org/posts/2026-11-05-openssh-password-authentication-bypass/

## Check your own image

```sh
docker run --rm -it --entrypoint sh YOURIMAGE -c '
  ldd /usr/sbin/sshd | grep -iE "musl|pam"          # musl + no pam?
  awk -F: "\$2==\"*\"{print \$1}" /etc/shadow        # any * accounts?
  awk -F: "\$2 ~ /^\\\$/{print \$1}" /etc/shadow      # any real hashes?
  grep -iE "passwordauthentication|permitrootlogin" /etc/ssh/sshd_config
'
```
