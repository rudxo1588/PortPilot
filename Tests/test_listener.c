// Test-only TCP listener. It owns all sockets and exits when its controller closes stdin.
#include <arpa/inet.h>
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static volatile sig_atomic_t terms = 0;
static volatile sig_atomic_t expired = 0;
static void term_handler(int sig) { (void)sig; terms++; }
static void alarm_handler(int sig) { (void)sig; expired = 1; }

static int open_listener(const char *bind_address, unsigned short requested_port,
                         unsigned short *actual_port) {
    const int ipv6 = strchr(bind_address, ':') != NULL;
    const int family = ipv6 ? AF_INET6 : AF_INET;
    int descriptor = socket(family, SOCK_STREAM, 0);
    if (descriptor < 0) return -1;
    if (ipv6) {
        int only_ipv6 = 1;
        if (setsockopt(descriptor, IPPROTO_IPV6, IPV6_V6ONLY, &only_ipv6, sizeof(only_ipv6)) != 0) {
            close(descriptor);
            return -1;
        }
    }
    struct sockaddr_storage storage;
    memset(&storage, 0, sizeof(storage));
    socklen_t length;
    if (ipv6) {
        struct sockaddr_in6 *address = (struct sockaddr_in6 *)&storage;
        address->sin6_family = AF_INET6;
        address->sin6_port = htons(requested_port);
        if (inet_pton(AF_INET6, bind_address, &address->sin6_addr) != 1) { close(descriptor); return -1; }
        length = sizeof(*address);
    } else {
        struct sockaddr_in *address = (struct sockaddr_in *)&storage;
        address->sin_family = AF_INET;
        address->sin_port = htons(requested_port);
        if (inet_pton(AF_INET, bind_address, &address->sin_addr) != 1) { close(descriptor); return -1; }
        length = sizeof(*address);
    }
    if (bind(descriptor, (struct sockaddr *)&storage, length) != 0 || listen(descriptor, 4) != 0) {
        close(descriptor);
        return -1;
    }
    if (getsockname(descriptor, (struct sockaddr *)&storage, &length) != 0) { close(descriptor); return -1; }
    *actual_port = ipv6 ? ntohs(((struct sockaddr_in6 *)&storage)->sin6_port)
                        : ntohs(((struct sockaddr_in *)&storage)->sin_port);
    return descriptor;
}

int main(int argc, char **argv) {
    const int ignore_term = argc > 1 && strcmp(argv[1], "ignore-term") == 0;
    const int count = argc > 2 ? atoi(argv[2]) : 1;
    const int requested_port = argc > 3 ? atoi(argv[3]) : 0;
    const char *bind_address = argc > 4 ? argv[4] : "127.0.0.1";
    if (count < 1 || count > 8) return 2;
    if (requested_port < 0 || requested_port > 65535 || (requested_port && count != 1)) return 2;
    int active_count = count;
    int sockets[8];
    unsigned short ports[8];
    for (int i = 0; i < count; i++) {
        sockets[i] = open_listener(bind_address, (unsigned short)requested_port, &ports[i]);
        if (sockets[i] < 0) return 3;
    }
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = term_handler;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGTERM, &action, NULL) != 0) return 7;
    action.sa_handler = alarm_handler;
    if (sigaction(SIGALRM, &action, NULL) != 0) return 8;
    alarm(180); // An abandoned test fixture cannot listen indefinitely.
    printf("{\"pid\":%d,\"ports\":[", getpid());
    for (int i = 0; i < count; i++) printf("%s%u", i ? "," : "", ports[i]);
    puts("]}");
    fflush(stdout);

    sig_atomic_t reported = 0;
    while (!expired) {
        if (terms != reported) {
            reported = terms;
            printf("{\"termCount\":%d}\n", reported);
            fflush(stdout);
            if (!ignore_term) break;
        }
        struct pollfd input = { .fd = STDIN_FILENO, .events = POLLIN | POLLHUP };
        int ready = poll(&input, 1, 50);
        if (ready < 0 && errno == EINTR) continue;
        if (ready < 0) return 9;
        if (ready > 0 && (input.revents & (POLLIN | POLLHUP))) {
            char command[128];
            ssize_t bytes = read(STDIN_FILENO, command, sizeof(command));
            if (bytes <= 0) break;
            if (command[0] == 'x') break;
            if (command[0] == 'c' && sockets[0] >= 0) {
                close(sockets[0]);
                sockets[0] = -1;
                puts("{\"closedFirst\":true}");
                fflush(stdout);
            }
            if (command[0] == 'a' && active_count < 8) {
                int extra = open_listener("127.0.0.1", 0, &ports[active_count]);
                if (extra < 0) return 3;
                sockets[active_count++] = extra;
                puts("{\"addedPort\":true}");
                fflush(stdout);
            }
        }
    }
    for (int i = 0; i < active_count; i++) if (sockets[i] >= 0) close(sockets[i]);
    return 0;
}
