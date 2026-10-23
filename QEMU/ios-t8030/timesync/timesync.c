/*
 * timesync: keeps iOS's clock right under QEMU, for HackiOS run by hackios.sh.
 *
 * HackiOS sets the clock once, from the boot-arg epoch=. A VM resumed from a snapshot carries on from
 * the moment it was saved, so its clock is behind by however long it was off. This asks a time server
 * every 30 seconds and sets the clock when it is more than 2 seconds out. The host's clock comes first:
 * hackios.sh has QEMU's user network answer a connection to 10.0.2.100:37 with the host's
 * `date +%s.%N` (guestfwd); then time servers over SNTP (RFC 4330).
 *
 * usage: timesync [server ...]   (default: time.apple.com pool.ntp.org time.google.com)
 * Started from the boot job list (rc.jobs) as root.
 */
#include <arpa/inet.h>
#include <netdb.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#define NTP_UNIX_OFFSET 2208988800ULL   /* seconds from 1900 to 1970 */

static double
now(void)
{
	struct timeval tv;

	gettimeofday(&tv, NULL);
	return tv.tv_sec + tv.tv_usec / 1e6;
}

/* One SNTP exchange: the server's time, corrected for half the round trip; 0 on failure. */
static double
ask(const char *server)
{
	struct addrinfo hints = { .ai_family = AF_INET, .ai_socktype = SOCK_DGRAM }, *ai = NULL;
	unsigned char packet[48];
	struct timeval timeout = { 3, 0 };
	double sent, received, server_time = 0;
	int s;

	if (getaddrinfo(server, "123", &hints, &ai) != 0 || ai == NULL) {
		return 0;
	}
	s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
	if (s >= 0) {
		setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
		memset(packet, 0, sizeof(packet));
		packet[0] = 0x23;                       /* leap 0, version 4, mode 3 (client) */
		sent = now();
		if (sendto(s, packet, sizeof(packet), 0, ai->ai_addr, ai->ai_addrlen) == sizeof(packet) &&
		    recv(s, packet, sizeof(packet), 0) == sizeof(packet) && (packet[0] & 7) == 4 && packet[1] != 0) {
			/* the transmit timestamp: seconds and fraction since 1900, big-endian */
			uint32_t seconds = (uint32_t)packet[40] << 24 | packet[41] << 16 | packet[42] << 8 | packet[43];
			uint32_t fraction = (uint32_t)packet[44] << 24 | packet[45] << 16 | packet[46] << 8 | packet[47];

			received = now();
			if (seconds > NTP_UNIX_OFFSET) {
				server_time = (seconds - NTP_UNIX_OFFSET) + fraction / 4294967296.0 + (received - sent) / 2;
			}
		}
		close(s);
	}
	freeaddrinfo(ai);
	return server_time;
}

/* The host's clock through QEMU (see above); 0 when it does not answer. */
static double
ask_host(void)
{
	struct sockaddr_in host = { .sin_family = AF_INET, .sin_port = htons(37) };
	struct timeval timeout = { 3, 0 };
	char text[64];
	ssize_t n, got = 0;
	double t = 0;
	int s = socket(AF_INET, SOCK_STREAM, 0);

	if (s < 0) {
		return 0;
	}
	inet_pton(AF_INET, "10.0.2.100", &host.sin_addr);
	setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
	setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
	if (connect(s, (struct sockaddr *)&host, sizeof(host)) == 0) {
		while (got < (ssize_t)sizeof(text) - 1 && (n = recv(s, text + got, sizeof(text) - 1 - got, 0)) > 0) {
			got += n;
		}
		text[got] = 0;
		t = strtod(text, NULL);
		if (t < 1.6e9) {                        /* not a time of this century: no answer */
			t = 0;
		}
	}
	close(s);
	return t;
}

static void
correct(double t, const char *source)
{
	double off = t - now();

	if (off > 2 || off < -2) {
		struct timeval tv = { (time_t)t, (suseconds_t)((t - (time_t)t) * 1e6) };

		if (settimeofday(&tv, NULL) == 0) {
			printf("timesync: clock was %+.0f s out, set from %s\n", -off, source);
		} else {
			perror("timesync: settimeofday");
		}
	}
}

int
main(int argc, char **argv)
{
	static const char *defaults[] = { "time.apple.com", "pool.ntp.org", "time.google.com" };
	const char **servers = argc > 1 ? (const char **)argv + 1 : defaults;
	int count = argc > 1 ? argc - 1 : 3;

	setvbuf(stdout, NULL, _IOLBF, 0);
	for (;;) {
		double t = ask_host();

		if (t != 0) {
			correct(t, "the host");
		} else {
			for (int i = 0; i < count; i++) {
				if ((t = ask(servers[i])) != 0) {
					correct(t, servers[i]);
					break;
				}
			}
		}
		sleep(30);
	}
}
