# Musl platform assessment

Checked on 2026-11-05. All runtime tests used local containers with ports
bound to `127.0.0.1`. No public host was scanned.

The result levels are distinct:

- **Runtime tested** means the packaged `sshd` handled live SSH attempts.
- **Package inspected** means the package version, linkage, and effective
  configuration were checked locally.
- **Source verified** means the build recipe and defaults were checked. It
  does not claim that a complete image was built or booted.

## Results

| Platform | Evidence level | Tested state | Result |
|---|---|---|---|
| OpenWrt 24.10.8 | OpenSSH runtime tested; stock image inspected | Stock Dropbear; optional `openssh-server` 9.9_p2-r1 | Stock path is not affected. Optional OpenSSH reproduced the bypass. |
| OpenWrt 25.12.0 | OpenSSH runtime tested; stock image inspected | Stock Dropbear; optional `openssh-server` 10.6_p1-r2 | Stock path is not affected. Optional OpenSSH reproduced the bypass. |
| Buildroot 2026.08.1 and master | Source verified | musl + OpenSSH 10.6p1 + PAM off | Affected configuration. Stock `qemu_x86_64_defconfig` has no SSH server. |
| OE-Core master and whinlatter | Source verified | musl + OpenSSH + PAM absent | Affected configuration. `core-image-minimal` has no SSH server by default. |
| Void Linux musl | Runtime tested | OpenSSH 10.6p2_1 + `UsePAM yes` | Fixed package denied the bypass and accepted a valid password. |
| Chimera Linux | Runtime tested | OpenSSH 10.6_p2-r0 + `UsePAM yes` | Fixed package denied the bypass and accepted a valid password. |
| Gentoo musl | Source verified | OpenSSH 10.6_p1 with non-default `USE=-pam` | Conditionally affected. Normal Linux profiles enable PAM. |
| Adelie Linux | Source verified | OpenSSH 9.9_p2-r1 with PAM | This non-PAM path is excluded. |
| postmarketOS | Source verified | Base package depends on `openssh-server-pam` | This non-PAM path is excluded. |

## OpenWrt runtime

The official rootfs images were:

- `ghcr.io/openwrt/rootfs:aarch64_generic-24.10.8`, index digest
  `sha256:dbe092b7f10824b858e0f6a4501f572e15c5c8739b2815010fbc2868870ea60a`
- `ghcr.io/openwrt/rootfs:aarch64_generic-25.12.0`, index digest
  `sha256:2e8d2238d4beb5ba4b5c2014a7715b9ce3c4313e68c598ba58e157dc3783d415`

Both stock root filesystems contained Dropbear and no OpenSSH server. The
signed release feeds supplied the optional packages shown in the table.
`ldd` showed musl, OpenSSL, and zlib, with no PAM library. `UsePAM` was an
unsupported option, which confirms the non-PAM build.

Each isolated test added one login-shell account with a literal `*` shadow
field and one account with a valid `$6$` hash. Password authentication was
enabled only on the container test port. The controls and result were:

```text
short wrong password, one prompt    denied
300-byte password, one prompt       denied
300-byte password, two prompts      accepted as victim
valid donor password, one prompt    accepted as alice
```

The first long attempt primes OpenSSH's per-connection salt cache. The second
attempt matches musl's `crypt()` failure marker. This is why a one-prompt test
alone gives a false safe result.

Stock OpenWrt is not directly exposed through this path. Its default SSH
server is Dropbear, and its literal-`*` service accounts use `/bin/false`.
A practical OpenSSH case needs the optional package, password authentication,
and a login-capable `*` account. The default firewall rejects WAN input, so
WAN reachability also needs an explicit rule or equivalent customization.

OpenWrt has merged fixes, but the tested 24.10.8 and 25.12.0 release feeds
still supplied the vulnerable packages at test time. The 24.10 source fix
bumps the package to `9.9_p2-r2` and backports the upstream mitigation. The
25.12 source tree now uses 10.6p2. Assess the full package revision and
restart `sshd` after updating.

Primary sources:

- [OpenWrt default package set](https://github.com/openwrt/openwrt/blob/openwrt-25.12/include/target.mk)
- [OpenWrt 24.10 OpenSSH fix](https://github.com/openwrt/packages/commit/4d71f2824715a090f7e9dfe8da73f5a40ade8bad)
- [OpenWrt 24.10.8 package feed](https://downloads.openwrt.org/releases/24.10.8/packages/aarch64_generic/packages/)
- [OpenWrt 25.12.0 package feed](https://downloads.openwrt.org/releases/25.12.0/packages/aarch64_generic/packages/)
- [OpenWrt firewall defaults](https://git.openwrt.org/?p=openwrt/openwrt.git;a=blob;f=package/network/config/firewall4/files/firewall.config;hb=openwrt-25.12)

## Buildroot

Buildroot is a build system, not one fixed distribution image. Release
2026.08.1 and master commit
`d1fad27e965805c0e4e201994021cd9acf48b0a5` select OpenSSH 10.6p1.
The recipe uses `--without-pam` unless `BR2_PACKAGE_LINUX_PAM=y`. Buildroot
restricts its libxcrypt package to glibc, so a musl build uses musl `crypt()`.

The affected combination is:

```text
BR2_TOOLCHAIN_BUILDROOT_MUSL=y
BR2_PACKAGE_OPENSSH=y
BR2_PACKAGE_OPENSSH_SERVER=y
# BR2_PACKAGE_LINUX_PAM is not set
```

The stock `qemu_x86_64_defconfig` has no SSH server. Stock literal-`*`
service accounts also use `/bin/false`. An exposed target needs OpenSSH to be
selected, a login-capable `*` account, a suitable hash donor, password
authentication, and reachable networking. PAM, glibc/libxcrypt, Dropbear, or
the upstream fix removes this path.

Primary sources:

- [Buildroot OpenSSH recipe](https://github.com/buildroot/buildroot/blob/d1fad27e965805c0e4e201994021cd9acf48b0a5/package/openssh/openssh.mk)
- [Buildroot libxcrypt configuration](https://github.com/buildroot/buildroot/blob/d1fad27e965805c0e4e201994021cd9acf48b0a5/package/libxcrypt/Config.in)
- [Buildroot QEMU x86_64 defconfig](https://github.com/buildroot/buildroot/blob/d1fad27e965805c0e4e201994021cd9acf48b0a5/configs/qemu_x86_64_defconfig)

## Yocto and OE-Core

OE-Core is also configuration-dependent. At master commit
`35d103be8b1a2346b7d0a7ff83745ad74d6817e2`, the OpenSSH 10.6p1 recipe uses
PAM only when `pam` is in `DISTRO_FEATURES`. `TCLIBC=musl` makes musl the
`virtual/crypt` provider. The historical whinlatter branch has the same logic
with OpenSSH 10.2p1.

The affected combination is:

```text
TCLIBC = "musl"
EXTRA_IMAGE_FEATURES += "ssh-server-openssh"
# pam is absent from DISTRO_FEATURES
```

`core-image-minimal` includes no SSH server by default. The image features
select either OpenSSH or Dropbear. PAM, glibc/libxcrypt, Dropbear, or fixed
OpenSSH removes this path. A complete Yocto image was not built in this
assessment. The repository's Alpine lab runtime-tests the same OpenSSH,
musl, and non-PAM authentication path.

Primary sources:

- [OE-Core OpenSSH 10.6p1 recipe](https://github.com/openembedded/openembedded-core/blob/35d103be8b1a2346b7d0a7ff83745ad74d6817e2/meta/recipes-connectivity/openssh/openssh_10.6p1.bb)
- [OE-Core musl provider configuration](https://github.com/openembedded/openembedded-core/blob/35d103be8b1a2346b7d0a7ff83745ad74d6817e2/meta/conf/distro/include/tclibc-musl.inc)
- [OE-Core image SSH features](https://github.com/openembedded/openembedded-core/blob/35d103be8b1a2346b7d0a7ff83745ad74d6817e2/meta/classes-recipe/core-image.bbclass)

## Other musl distributions

The current official Void musl image had digest
`sha256:1425938d1ece86e601f16c044eac375857cbf5a2f9d2a8ebed0b385c15769f54`.
It installed `openssh-10.6p2_1`. The `sshd-auth` binary linked to musl and
`libpam.so.0`; `sshd -T` reported `UsePAM yes`. A two-prompt 300-byte attempt
against a controlled `*` account was denied. A valid password was accepted.

The current official Chimera image had digest
`sha256:b58ec2b8c80561ba8f41d8852463585d22299b38737ce36d7d926cabf9c94174`.
It installed `openssh-10.6_p2-r0`. Its `sshd-auth` binary also linked to musl
and `libpam.so.0`; the packaged template resolved to `UsePAM yes`. The minimal
container does not run Chimera's normal boot provisioning, so the runtime
control used a direct `pam_unix` policy. The long attempt was denied and the
valid password was accepted.

Gentoo is the strongest remaining conditional case. Its 10.6_p1 ebuild makes
PAM optional, while the musl `virtual/libcrypt` provider remains musl. Normal
Linux profiles enable PAM and the ebuild configures `UsePAM yes` with password
authentication disabled. A custom musl system built with `USE=-pam` can enter
the affected state until it receives the fixed OpenSSH package.

Primary sources:

- [Void OpenSSH template](https://raw.githubusercontent.com/void-linux/void-packages/master/srcpkgs/openssh/template)
- [Chimera OpenSSH template](https://raw.githubusercontent.com/chimera-linux/cports/master/main/openssh/template.py)
- [Gentoo OpenSSH 10.6_p1 ebuild](https://gitweb.gentoo.org/repo/gentoo.git/plain/net-misc/openssh/openssh-10.6_p1.ebuild)
- [Adelie OpenSSH recipe](https://git.adelielinux.org/api/v4/projects/adelie%2Fpackages/repository/files/system%2Fopenssh%2FAPKBUILD/raw?ref=current)
- [postmarketOS base package](https://pkgs.postmarketos.org/package/main/postmarketos/aarch64/postmarketos-base)
