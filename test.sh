#!/usr/bin/env bash
# usage: ./test.sh [10.6p1|10.6p1-pam|10.6p1-pam-off|10.6p2]
set -uo pipefail
cd "$(dirname "$0")" || exit 1

VER="${1:-10.6p1}"
CTR=sshhole
IMG=sshhole

case "$VER" in
  10.6p1)
    BUILD=10.6p1; PAM_OPTION=; AUTH_PATH="no PAM"; STAR_LONG_WANT=OK ;;
  10.6p1-pam)
    BUILD=10.6p1-pam; PAM_OPTION='-o UsePAM=yes'; AUTH_PATH="UsePAM yes"; STAR_LONG_WANT=NO ;;
  10.6p1-pam-off)
    BUILD=10.6p1-pam; PAM_OPTION='-o UsePAM=no'; AUTH_PATH="UsePAM no"; STAR_LONG_WANT=OK ;;
  10.6p2)
    BUILD=10.6p2; PAM_OPTION=; AUTH_PATH="no PAM"; STAR_LONG_WANT=NO ;;
  *) echo "unsupported version: $VER" >&2; exit 2 ;;
esac

echo "[*] building image (cached after the first run)"
docker build --quiet -t "$IMG" lab/ >/dev/null || exit 1

docker rm -f "$CTR" >/dev/null 2>&1 || true
docker run -d --name "$CTR" -p 127.0.0.1:2222:2222 "$IMG" >/dev/null || exit 1

if [ "$BUILD" = 10.6p1-pam ]; then
  # PAM_OPTION is two sshd arguments here.
  # shellcheck disable=SC2086
  docker exec "$CTR" /opt/openssh-10.6p1-pam/sbin/sshd -T \
    -f /etc/ssh/sshd_config $PAM_OPTION | \
    grep -i "^UsePAM ${PAM_OPTION##*=}$" >/dev/null || exit 1
fi

# Start the requested sshd build on port 2222.
docker exec -d "$CTR" sh -c "/opt/openssh-$BUILD/sbin/sshd -D -e -o LogLevel=VERBOSE -f /etc/ssh/sshd_config $PAM_OPTION > /tmp/sshd.log 2>&1"

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
ALICE_PW='correct horse battery staple'
failures=0

ASKPASS=$(mktemp "${TMPDIR:-/tmp}/sshhole-askpass.XXXXXX") || exit 1
trap 'rm -f "$ASKPASS"' EXIT HUP INT TERM
# SSHPASS expands when ssh runs this helper for each password prompt.
# shellcheck disable=SC2016
printf '#!/bin/sh\nprintf "%%s" "$SSHPASS"\n' > "$ASKPASS"
chmod 700 "$ASKPASS"

try() { # user pass nprompts [remote-command...]
  local user="$1" pass="$2" prompts="$3"; shift 3
  local cmd="$*"
  [ -n "$cmd" ] || cmd='echo __AUTH_OK__; id -un; id -u'

  SSHPASS="$pass" SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force DISPLAY=x \
    ssh -F /dev/null -p 2222 \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o PreferredAuthentications=password -o PubkeyAuthentication=no \
      -o NumberOfPasswordPrompts="$prompts" -o ConnectTimeout=5 -o LogLevel=ERROR \
      "$user@127.0.0.1" "$cmd" </dev/null 2>&1
}

check() { # desc expected(OK|NO) user pass prompts [remote-command...]
  local desc="$1" want="$2" user="$3" pass="$4" prompts="$5"
  shift 5
  local out rc
  out=$(try "$user" "$pass" "$prompts" "$@" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q __AUTH_OK__; then
    got=OK
  else
    got=NO
  fi
  local mark="  "
  if [ "$got" != "$want" ]; then
    mark=">>"
    failures=$((failures + 1))
  fi
  printf '%s %-46s want=%-3s got=%-3s %s\n' "$mark" "$desc" "$want" "$got" "$(printf '%s' "$out" | tail -1)"
}

echo "=== OpenSSH $VER on Alpine/musl, $AUTH_PATH, port 2222 ==="
echo

check "victim('*') + 300 x A, 1 prompt" NO victim "$LONG" 1
check "victim('*') + 300 x A, 2 prompts" "$STAR_LONG_WANT" victim "$LONG" 2
check "victim('*') + short wrong pw"   NO victim 'wrongpassword' 3
check "alice(real) + correct pw"       OK alice "$ALICE_PW" 1
check "alice(real) + 300 x A"          NO alice "$LONG" 3
# The command is expanded by the remote shell, not this script.
# shellcheck disable=SC2016
check "alpine('*') + 300 x A + doas"  "$STAR_LONG_WANT" alpine "$LONG" 2 \
  'echo __AUTH_OK__; test "$(doas id -u)" = 0'
check "root('*') + 300 x A"            "$STAR_LONG_WANT" root "$LONG" 2
check "root('*') + short wrong pw"     NO root 'wrongpassword' 3
echo
echo "--- sshd log tail ---"
docker exec "$CTR" sh -c 'tail -20 /tmp/sshd.log' || true

if [ "$failures" -ne 0 ]; then
  echo "FAILED: $failures assertion(s)" >&2
  exit 1
fi
echo "PASS: all assertions"
