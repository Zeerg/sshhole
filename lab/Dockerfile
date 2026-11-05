FROM alpine:3.21@sha256:ee16d92f96db08d9d2d07da48555a27f3a69d8f0759021dbc601195ed0d2b5bd

# build dependencies for openssh-portable
RUN apk add --no-cache \
      gcc musl-dev openssl openssl-dev zlib-dev linux-headers make \
      linux-pam-dev

# Build vulnerable and patched non-PAM servers, plus a vulnerable 10.6p1
# control that routes password authentication through PAM.
RUN set -eux; \
    for v in 10.6p1 10.6p2; do \
      case "$v" in \
        10.6p1) sha256=a9dc9565dffe8640f64d863cd29a32bc4a3dbdec0566a7fc44c5d6ee767d5f39 ;; \
        10.6p2) sha256=9ae44872090cf2f06b3cf9ff147e7f16f309671340763ed2f99248398ae29d5b ;; \
      esac; \
      wget -q "https://cdn.openbsd.org/pub/OpenBSD/OpenSSH/portable/openssh-${v}.tar.gz" -O "/tmp/openssh-${v}.tar.gz"; \
      echo "${sha256}  /tmp/openssh-${v}.tar.gz" | sha256sum -c -; \
      tar xzf "/tmp/openssh-${v}.tar.gz" -C /tmp; \
      cd "/tmp/openssh-${v}"; \
      ./configure --prefix="/opt/openssh-${v}" --sysconfdir=/etc/ssh \
        --without-pam --without-kerberos5; \
      make -j"$(nproc)"; \
      make install; \
      if [ "$v" = 10.6p1 ]; then \
        make distclean; \
        ./configure --prefix=/opt/openssh-10.6p1-pam --sysconfdir=/etc/ssh \
          --with-pam --without-kerberos5; \
        make -j"$(nproc)"; \
        make install; \
      fi; \
      cd /; rm -rf "/tmp/openssh-${v}" "/tmp/openssh-${v}.tar.gz"; \
    done

# privilege-separation user (make install may have created it already) + runtime dirs
RUN id sshd >/dev/null 2>&1 || adduser -D -H -s /bin/false sshd; \
    mkdir -p /run/sshd /var/empty

# test accounts:
#   alice  -> real sha512crypt password; its hash is what pick_salt() borrows
#           (stands in for ANY provisioned password on a real box)
#   victim -> '*' shadow field (key-only-style locked account)
#   alpine -> '*' shadow field + wheel + 'permit nopass :wheel' doas,
#             replicating the account model in affected tiny-cloud images
#   root   -> '*' shadow field (PermitRootLogin yes => direct uid=0 demo)
RUN apk add --no-cache doas
RUN set -eux; \
    HASH="$(openssl passwd -6 'correct horse battery staple')"; \
    adduser -D -H -s /bin/sh alice; \
    adduser -D -H -s /bin/sh victim; \
    addgroup alpine; \
    adduser -D -H -s /bin/sh -G alpine alpine; \
    addgroup alpine wheel; \
    sed -i -e "s|^alice:[^:]*:|alice:${HASH}:|" \
           -e 's|^victim:[^:]*:|victim:*:|' \
           -e 's|^alpine:[^:]*:|alpine:*:|' \
           -e 's|^root:[^:]*:|root:*:|' /etc/shadow; \
    mkdir -p /etc/doas.d; \
    echo 'permit nopass :wheel' > /etc/doas.d/wheel.conf; \
    grep -q 'permit nopass :wheel' /etc/doas.conf 2>/dev/null || \
      echo 'permit nopass :wheel' >> /etc/doas.conf; \
    awk -F: '$1 ~ /^(root|alice|victim|alpine|sshd)$/ {print $1" -> "substr($2,1,14)}' /etc/shadow

RUN mkdir -p /etc/pam.d; \
    printf '%s\n' \
      'auth required pam_unix.so' \
      'account required pam_unix.so' \
      'password required pam_unix.so' \
      'session required pam_unix.so' > /etc/pam.d/sshd

# host keys shared by all sshd builds
RUN /opt/openssh-10.6p1/bin/ssh-keygen -A

COPY sshd_config /etc/ssh/sshd_config

CMD ["sleep", "infinity"]
