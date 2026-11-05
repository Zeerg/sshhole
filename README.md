# sshhole — OpenSSH/musl password-auth bypass

## BLUF

> Unpatched Portable OpenSSH **7.3p1 through 10.6p1** has a remote
> password-authentication bypass on Linux systems using **musl libc** when
> password authentication does not use PAM. If a reachable account has a
> literal `*` password field and another account supplies a `$5$` or `$6$`
> hash, an unauthenticated attacker can use any 257-1024 byte password on the
> **second password attempt in one SSH connection**. This can become root
> access when the target is `root` or has passwordless `doas` or `sudo`.
> Upstream fixed the issue in **OpenSSH 10.6p2**. Vendors also backported the
> fix to older package versions. **Standard Ubuntu, Debian, and RHEL-family
> installations are not affected by this specific path** because their
> OpenSSH packages use glibc or libxcrypt and normally route password
> authentication through PAM.

This repository reproduces the issue end-to-end against OpenSSH 10.6p1 and
uses 10.6p2 as the fixed control:

```sh
./poc.sh            # one prompt denied, two prompts reach a root doas shell
./poc.sh 10.6p2     # same two-prompt attempt denied by the fix
./test.sh           # assertion matrix
```

![Terminal demo: OpenSSH 10.6p1 reaches a root shell through alpine and doas while 10.6p2 denies the same attempt](assets/demo.gif)

Source: https://sshhole.com (found by Ozgun Kultekin / Wakefield).
Requires Docker and an OpenSSH client. Use this lab only on systems you own.

## Affected versions

The vulnerable upstream path is present in Portable OpenSSH 7.3p1 through
10.6p1, inclusive. OpenSSH 7.3p1 introduced the salt-selection behavior while
fixing CVE-2016-6210. The
[Portable OpenSSH 10.6p2 release](https://www.openssh.com/txt/release-10.6p2)
added the authentication check that prevents a short lock marker such as `*`
from matching `crypt()` output.

Version strings are not sufficient for package assessment. Linux vendors
backported the fix to older OpenSSH branches. For example, the
[Alpine security advisory](https://alpinelinux.org/posts/2026-11-05-openssh-password-authentication-bypass/)
lists fixed package revisions based on OpenSSH 9.0p1 through 10.3p1. Use the
vendor security advisory and full package revision as the authority. Also
restart `sshd`: installing a fixed package does not replace an already running
daemon.

This demonstrated path is specific to Portable OpenSSH's non-PAM `crypt()`
path on musl. It does not apply to native OpenBSD's BSD-auth path,
`UsePAM yes`, or current Dropbear. The same `*` match does not occur with
glibc or libxcrypt.

## Preconditions

All of these conditions are required:

1. The server runs Linux with musl libc.
2. The password method does not use PAM. This includes builds without PAM and
   builds with `UsePAM no`.
3. `PasswordAuthentication yes` is effective for the target account.
4. The target resolves to a literal `*` password field.
5. Another account provides a `$5$` or `$6$` password hash for `pick_salt()`.
6. The client can send a 257-1024 byte password at least twice in one SSH
   connection.
7. Direct root access also requires `PermitRootLogin yes`. A non-root target
   with passwordless `doas` or `sudo` does not require that setting.

Official Alpine tiny-cloud images from 3.18.11 through 3.24.3 shipped an
`alpine:*` user with passwordless `doas`. A fresh image without a `$5$` or
`$6$` salt donor is not exploitable through this path. It becomes exploitable
when configuration adds a suitable password hash, for example through a
console password or a user-data `hashed_passwd` entry. Images built from
3.21.10, 3.22.8, 3.23.8, and 3.24.4 include the fixed package.

## Remediation

Install the vendor's fixed OpenSSH package and restart `sshd`. On Alpine:

```sh
apk upgrade -U -a
sshd -t && rc-service sshd restart
```

Using PAM also prevents this specific path on an older OpenSSH build, but only
when sshd was built with PAM support and the effective configuration has
`UsePAM yes`. The lab verifies this against the vulnerable 10.6p1 source:

```sh
./test.sh 10.6p1-pam-off  # PAM-linked binary with UsePAM no: vulnerable
./test.sh 10.6p1-pam
```

The same PAM-linked 10.6p1 binary remains vulnerable with `UsePAM no`. With
`UsePAM yes`, it denies every long-password attempt against a `*` account
while still accepting Alice's valid password. Confirm the effective setting
with `sshd -T | grep -i '^usepam '`. Treat PAM as a temporary mitigation, not
a substitute for installing the fixed package and restarting sshd.

If an update is not immediately available, disable password authentication in
the effective `sshd` configuration, validate it, and restart the daemon:

```text
PasswordAuthentication no
```

```sh
sshd -t && rc-service sshd restart
sshd -T | grep -i '^passwordauthentication '
```

Keep the current administrative session open until a new key-based session
works. Check `Match` blocks because they can override the global setting.

For incident review, look for a `Failed password` event followed by an
`Accepted password` event for the same account, source address, and connection.
Give special attention to `root`, `alpine`, directory-service users, and
key-only accounts. If an exposed `*` account accepted a password, treat the
host as compromised.

The full `./test.sh` matrix on 10.6p1 verifies:

```
[-] victim '*' + 300xA, 1 prompt      -> denied          (cold salt cache)
[+] victim '*' + 300xA, prompts 1+2   -> victim 1001
[+] alpine '*' + 300xA, prompts 1+2   -> alpine → root 0 (doas)
[+] root   '*' + 300xA, prompts 1+2   -> root 0
[-] victim '*' + wrong pw x3          -> denied
[+] alice  real pw                    -> alice 1000
[-] alice  real + 300xA x3            -> denied
```

## Musl platform assessment

The [musl platform assessment](research/musl-platforms.md) separates local
runtime tests from package inspection and source-only configuration analysis.
The tested signed OpenWrt 24.10.8 and 25.12.0 release feeds reproduced the
bypass after the optional non-PAM OpenSSH server was installed. Stock OpenWrt
uses Dropbear and is not affected by this path. Current Void musl and Chimera
packages use OpenSSH 10.6p2 with PAM and denied the same attempt. Buildroot,
OE-Core, and Gentoo musl remain configuration-dependent.

## License

This repository's original content is available under the [MIT License](LICENSE).
