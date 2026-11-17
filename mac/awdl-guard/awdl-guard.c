/*
 * awdl-guard: keep Apple Wireless Direct Link quiet while a game stream is running.
 *
 * AWDL (AirDrop, AirPlay, Sidecar, Universal Control) makes the Wi-Fi radio leave the access
 * point's channel several times per second to listen on the AWDL social channels. Every hop
 * delays incoming video packets by up to tens of milliseconds, which shows up as periodic
 * stutter and latency spikes in Moonlight. awdl-guard brings awdl0 (and llw0) down only while
 * Moonlight is actually streaming, re-downs them the instant macOS raises them again (routing
 * socket notification, no polling delay), and restores them when the stream ends so AirDrop
 * keeps working the rest of the time.
 *
 * "Streaming" = a process named Moonlight owns at least two UDP sockets that are not mDNS
 * (video, audio and control channels). The Moonlight UI alone only holds mDNS sockets.
 *
 * Runs as a root LaunchDaemon. Build: clang -O2 -arch arm64 -arch x86_64 -o awdl-guard awdl-guard.c
 * Usage: awdl-guard            run the daemon
 *        awdl-guard --status   print interface and stream state, then exit
 *        touch /var/run/lightpath-awdl-off   force AWDL off even without a stream
 */
#include <errno.h>
#include <libproc.h>
#include <net/if.h>
#include <net/route.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/proc_info.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

static const char *const kInterfaces[] = {"awdl0", "llw0"};
static const char *const kClients[] = {"Moonlight"};
static const char *const kForceFile = "/var/run/lightpath-awdl-off";
static const int kStreamReleaseSeconds = 3; /* hysteresis after the stream ends */

static volatile sig_atomic_t g_stop = 0;

static void on_signal(int sig)
{
    (void)sig;
    g_stop = 1;
}

static bool is_client(pid_t pid)
{
    char name[2 * MAXCOMLEN + 1];
    memset(name, 0, sizeof(name));
    if (proc_name(pid, name, sizeof(name)) <= 0) {
        return false;
    }
    for (size_t i = 0; i < sizeof(kClients) / sizeof(kClients[0]); i++) {
        if (strcmp(name, kClients[i]) == 0) {
            return true;
        }
    }
    return false;
}

/* Number of UDP sockets of a process that are not mDNS. Returns -1 if it cannot be inspected. */
static int streaming_sockets(pid_t pid)
{
    int size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (size <= 0) {
        return -1;
    }
    struct proc_fdinfo *fds = malloc((size_t)size);
    if (fds == NULL) {
        return -1;
    }
    size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, size);
    int count = 0;
    int n = size / (int)PROC_PIDLISTFD_SIZE;
    for (int i = 0; i < n; i++) {
        if (fds[i].proc_fdtype != PROX_FDTYPE_SOCKET) {
            continue;
        }
        struct socket_fdinfo si;
        if (proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &si, sizeof(si)) != (int)sizeof(si)) {
            continue;
        }
        if (si.psi.soi_kind != SOCKINFO_IN || si.psi.soi_protocol != IPPROTO_UDP) {
            continue;
        }
        int lport = ntohs((uint16_t)si.psi.soi_proto.pri_in.insi_lport);
        if (lport != 0 && lport != 5353) {
            count++;
        }
    }
    free(fds);
    return count;
}

static bool stream_active(void)
{
    int n = proc_listallpids(NULL, 0);
    if (n <= 0) {
        return false;
    }
    n += 64;
    pid_t *pids = calloc((size_t)n, sizeof(pid_t));
    if (pids == NULL) {
        return false;
    }
    n = proc_listallpids(pids, n * (int)sizeof(pid_t));
    bool active = false;
    for (int i = 0; i < n && !active; i++) {
        if (pids[i] <= 0 || !is_client(pids[i])) {
            continue;
        }
        int sockets = streaming_sockets(pids[i]);
        /* If we cannot look inside the process, err on the side of a quiet radio. */
        active = sockets < 0 || sockets >= 2;
    }
    free(pids);
    return active;
}

static int get_flags(int s, const char *ifname, short *flags)
{
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strlcpy(ifr.ifr_name, ifname, sizeof(ifr.ifr_name));
    if (ioctl(s, SIOCGIFFLAGS, &ifr) < 0) {
        return -1;
    }
    *flags = ifr.ifr_flags;
    return 0;
}

/* Returns 1 if the flag changed, 0 if it was already in the wanted state, -1 on error. */
static int set_up(int s, const char *ifname, bool up)
{
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strlcpy(ifr.ifr_name, ifname, sizeof(ifr.ifr_name));
    if (ioctl(s, SIOCGIFFLAGS, &ifr) < 0) {
        return -1;
    }
    short wanted = up ? (short)(ifr.ifr_flags | IFF_UP) : (short)(ifr.ifr_flags & ~IFF_UP);
    if (wanted == ifr.ifr_flags) {
        return 0;
    }
    ifr.ifr_flags = wanted;
    return ioctl(s, SIOCSIFFLAGS, &ifr) < 0 ? -1 : 1;
}

static void apply(int s, bool quiet)
{
    for (size_t i = 0; i < sizeof(kInterfaces) / sizeof(kInterfaces[0]); i++) {
        int r = set_up(s, kInterfaces[i], !quiet);
        if (r == 1) {
            syslog(LOG_NOTICE, "%s %s", kInterfaces[i], quiet ? "down (stream active)" : "up (stream ended)");
        } else if (r < 0 && errno != ENXIO && errno != ENODEV) {
            syslog(LOG_WARNING, "%s: %s", kInterfaces[i], strerror(errno));
        }
    }
}

static int status(int s)
{
    for (size_t i = 0; i < sizeof(kInterfaces) / sizeof(kInterfaces[0]); i++) {
        short flags = 0;
        if (get_flags(s, kInterfaces[i], &flags) == 0) {
            printf("%s: %s\n", kInterfaces[i], (flags & IFF_UP) ? "up" : "down");
        } else {
            printf("%s: absent\n", kInterfaces[i]);
        }
    }
    printf("stream: %s\n", stream_active() ? "active" : "idle");
    printf("forced off: %s\n", access(kForceFile, F_OK) == 0 ? "yes" : "no");
    return 0;
}

int main(int argc, char **argv)
{
    int ctl = socket(AF_INET, SOCK_DGRAM, 0);
    if (ctl < 0) {
        perror("socket");
        return 1;
    }
    if (argc > 1 && strcmp(argv[1], "--status") == 0) {
        return status(ctl);
    }

    openlog("lightpath-awdl-guard", LOG_PID, LOG_DAEMON);
    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    signal(SIGHUP, on_signal);

    /* Routing socket: RTM_IFINFO arrives the moment macOS raises awdl0 again. */
    int rt = socket(PF_ROUTE, SOCK_RAW, AF_UNSPEC);
    syslog(LOG_NOTICE, "started");

    bool quiet = false;
    time_t last_active = 0;
    while (!g_stop) {
        bool want = access(kForceFile, F_OK) == 0;
        if (stream_active()) {
            last_active = time(NULL);
            want = true;
        } else if (quiet && time(NULL) - last_active < kStreamReleaseSeconds) {
            want = true;
        }

        if (want || quiet) {
            apply(ctl, want);
        }
        quiet = want;

        /* Sleep until an interface changes or 500 ms pass. */
        if (rt >= 0) {
            fd_set rfds;
            FD_ZERO(&rfds);
            FD_SET(rt, &rfds);
            struct timeval tv = {0, 500000};
            if (select(rt + 1, &rfds, NULL, NULL, &tv) > 0) {
                char buf[4096];
                while (recv(rt, buf, sizeof(buf), MSG_DONTWAIT) > 0) {
                }
            }
        } else {
            usleep(500000);
        }
    }

    if (quiet) {
        apply(ctl, false);
    }
    syslog(LOG_NOTICE, "stopped");
    return 0;
}
