// Focused ABI and stale-generation probe. Signals only its own forked listener.
#include <arpa/inet.h>
#include <errno.h>
#include <libproc.h>
#include <mach/mach.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

// Layout verified against Apple's XNU xnu-10063.141.1 private proc_info ABI.
// https://github.com/apple-oss-distributions/xnu/blob/xnu-10063.141.1/bsd/sys/proc_info_private.h
struct probe_unique_info {
    uint8_t executable_uuid[16];
    uint64_t unique_id, parent_unique_id;
    int32_t id_version;
    uint32_t reserved2;
    uint64_t reserved3, reserved4;
};
struct probe_bsd_unique {
    struct proc_bsdinfo bsd;
    struct probe_unique_info unique;
};
_Static_assert(sizeof(struct probe_unique_info) == 56, "ABI size mismatch");
static volatile sig_atomic_t done;
static void term(int sig) { (void)sig; done = 1; }

int main(void) {
    int sockets[2], ports[2];
    for (int i = 0; i < 2; i++) {
        sockets[i] = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in address = {.sin_len = sizeof(address), .sin_family = AF_INET,
                                     .sin_port = 0, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
        if (sockets[i] < 0 || bind(sockets[i], (void*)&address, sizeof(address)) || listen(sockets[i], 2)) {
            perror("test listener"); return 1;
        }
        socklen_t size = sizeof(address);
        if (getsockname(sockets[i], (void*)&address, &size)) return 1;
        ports[i] = ntohs(address.sin_port);
    }
    int readiness[2];
    if (pipe(readiness)) return 1;
    pid_t child = fork();
    if (child < 0) return 1;
    if (child == 0) {
        close(readiness[0]);
        signal(SIGTERM, term);
        alarm(10); // Self-cleanup even if the parent probe fails.
        char ready = 'R';
        write(readiness[1], &ready, 1); close(readiness[1]);
        while (!done) pause();
        close(sockets[0]); close(sockets[1]);
        _exit(0);
    }
    close(readiness[1]);
    close(sockets[0]); close(sockets[1]);
    char ready = 0;
    if (read(readiness[0], &ready, 1) != 1 || ready != 'R') return 1;
    close(readiness[0]);
    struct probe_bsd_unique info = {0};
    int bytes = proc_pidinfo(child, 18, 0, &info, sizeof(info));
    printf("flavor18 bytes=%d expected=%zu uid=%u pid=%d version=%d ports=%d,%d\n",
           bytes, sizeof(info), info.bsd.pbi_uid, info.bsd.pbi_pid, info.unique.id_version, ports[0], ports[1]);
    if ((size_t)bytes != sizeof(info) || info.bsd.pbi_pid != (uint32_t)child || info.bsd.pbi_uid != getuid()) return 1;
    mach_port_t child_name = MACH_PORT_NULL;
    kern_return_t name_result = task_name_for_pid(mach_task_self(), child, &child_name);
    audit_token_t name_token = {{0}};
    mach_msg_type_number_t token_count = TASK_AUDIT_TOKEN_COUNT;
    kern_return_t token_result = name_result == KERN_SUCCESS
        ? task_info(child_name, TASK_AUDIT_TOKEN, (task_info_t)&name_token, &token_count)
        : name_result;
    printf("public task_name audit token: name=%d token=%d pid_match=%s version_match=%s\n",
           name_result, token_result, name_token.val[5] == (uint32_t)child ? "yes" : "no",
           name_token.val[7] == (uint32_t)info.unique.id_version ? "yes" : "no");
    if (child_name != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), child_name);
    audit_token_t token = {{0}};
    token.val[5] = (uint32_t)child;
    token.val[7] = (uint32_t)info.unique.id_version ^ 1U;
    int stale = proc_signal_with_audittoken(&token, SIGTERM);
    int status;
    pid_t alive = waitpid(child, &status, WNOHANG);
    printf("stale-generation SIGTERM errno=%d expected=%d child_alive=%s\n", stale, ESRCH, alive == 0 ? "yes" : "no");
    if (stale != ESRCH || alive != 0) return 1;
    token.val[7] = (uint32_t)info.unique.id_version;
    int normal = proc_signal_with_audittoken(&token, SIGTERM);
    pid_t ended = waitpid(child, &status, 0);
    printf("valid-generation SIGTERM errno=%d exit=%d\n", normal, ended == child && WIFEXITED(status) ? WEXITSTATUS(status) : -1);
    int gone = proc_signal_with_audittoken(&token, SIGTERM);
    printf("already-exited SIGTERM errno=%d expected=%d\n", gone, ESRCH);
    int free_ports = 0;
    for (int i = 0; i < 2; i++) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in address = {.sin_len = sizeof(address), .sin_family = AF_INET,
                                     .sin_port = htons(ports[i]), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
        if (fd >= 0 && bind(fd, (void*)&address, sizeof(address)) == 0) free_ports++;
        close(fd);
    }
    printf("released ports=%d expected=2\n", free_ports);
    return normal != 0 || ended != child || !WIFEXITED(status) || WEXITSTATUS(status) != 0 || gone != ESRCH || free_ports != 2;
}
