/*
 * lightpath-wake: send Wake-on-LAN / Wake-on-WLAN magic packets.
 *
 *   lightpath-wake <mac> <target> [<target>...]
 *
 * <mac>     e0:c2:64:71:4b:16 (dashes also accepted)
 * <target>  IPv4 address (broadcast addresses allowed), IPv6 address, or either with a port:
 *           10.0.0.255   10.0.0.120:9   2601:db8::1   [2601:db8::1]:40009   host.example
 *
 * Each target receives the packet 3 times, 120 ms apart (Wi-Fi drops are common and a
 * sleeping radio may miss the first one). The payload is the standard 6 x 0xFF followed by 16
 * repetitions of the MAC address, so any NIC with magic-packet wake enabled will match it,
 * whether it arrives as broadcast or unicast, over IPv4 or IPv6.
 */
#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int parse_mac(const char *text, unsigned char mac[6])
{
    unsigned int b[6];
    if (sscanf(text, "%2x%*[:-]%2x%*[:-]%2x%*[:-]%2x%*[:-]%2x%*[:-]%2x", &b[0], &b[1], &b[2], &b[3], &b[4], &b[5]) != 6) {
        return -1;
    }
    for (int i = 0; i < 6; i++) {
        mac[i] = (unsigned char)b[i];
    }
    return 0;
}

/* Split "host", "host:port", "[v6]" or "[v6]:port" into host and port strings. */
static void split_target(const char *target, char *host, size_t host_len, char *port, size_t port_len)
{
    snprintf(port, port_len, "9");
    if (target[0] == '[') {
        const char *end = strchr(target, ']');
        size_t n = end ? (size_t)(end - target - 1) : strlen(target) - 1;
        snprintf(host, host_len, "%.*s", (int)n, target + 1);
        if (end && end[1] == ':') {
            snprintf(port, port_len, "%s", end + 2);
        }
        return;
    }
    const char *colon = strchr(target, ':');
    if (colon && strchr(colon + 1, ':') == NULL) { /* exactly one colon: IPv4/hostname with port */
        snprintf(host, host_len, "%.*s", (int)(colon - target), target);
        snprintf(port, port_len, "%s", colon + 1);
    } else {
        snprintf(host, host_len, "%s", target); /* bare IPv6 or no port */
    }
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s <mac> <target> [<target>...]\n", argv[0]);
        return 2;
    }
    unsigned char mac[6];
    if (parse_mac(argv[1], mac) != 0) {
        fprintf(stderr, "invalid MAC address: %s\n", argv[1]);
        return 2;
    }
    unsigned char packet[102];
    memset(packet, 0xFF, 6);
    for (int i = 0; i < 16; i++) {
        memcpy(packet + 6 + i * 6, mac, 6);
    }

    int sent = 0;
    for (int round = 0; round < 3; round++) {
        for (int t = 2; t < argc; t++) {
            char host[256], port[16];
            split_target(argv[t], host, sizeof(host), port, sizeof(port));
            struct addrinfo hints, *res = NULL;
            memset(&hints, 0, sizeof(hints));
            hints.ai_family = AF_UNSPEC;
            hints.ai_socktype = SOCK_DGRAM;
            if (getaddrinfo(host, port, &hints, &res) != 0 || res == NULL) {
                if (round == 0) {
                    fprintf(stderr, "cannot resolve %s\n", argv[t]);
                }
                continue;
            }
            int s = socket(res->ai_family, SOCK_DGRAM, 0);
            if (s >= 0) {
                int on = 1;
                if (res->ai_family == AF_INET) {
                    setsockopt(s, SOL_SOCKET, SO_BROADCAST, &on, sizeof(on));
                }
                if (sendto(s, packet, sizeof(packet), 0, res->ai_addr, res->ai_addrlen) == (ssize_t)sizeof(packet)) {
                    sent++;
                }
                close(s);
            }
            freeaddrinfo(res);
        }
        usleep(120000);
    }
    printf("sent %d magic packets\n", sent);
    return sent > 0 ? 0 : 1;
}
