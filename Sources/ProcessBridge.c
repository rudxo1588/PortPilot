#include "ProcessBridge.h"
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/proc.h>
#include <sys/sysctl.h>
#include <bsm/audit.h>
#include <mach/mach.h>
#include <pwd.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <ctype.h>
#include <stdio.h>

/* Public read-only Mach name rights can query TASK_AUDIT_TOKEN. We acquire a
 * fresh name right on each side of the libproc reads, since an old task name
 * can outlive exec. Every right is deallocated; no task control right or
 * entitlement is requested. Apple XNU task.c task_info_from_user accepts name
 * rights for this flavor; exec changes pidversion in kern_exec.c.
 * https://github.com/apple-oss-distributions/xnu/blob/xnu-10063.141.1/osfmk/kern/task.c
 * https://github.com/apple-oss-distributions/xnu/blob/xnu-10063.141.1/bsd/kern/kern_exec.c
 */
static int pp_read_bsd(int32_t pid, struct proc_bsdinfo *out) {
    memset(out, 0, sizeof(*out));
    errno = 0;
    int size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0,
                           out, (int)sizeof(*out));
    if (size == 0) return errno ? errno : ESRCH;
    if (size != sizeof(*out) || out->pbi_pid != (uint32_t)pid)
        return ENOTSUP;
    if (out->pbi_status == SZOMB) return ESRCH;
    return 0;
}

static int pp_read_token(int32_t pid, audit_token_t *token) {
    mach_port_t name = MACH_PORT_NULL;
    kern_return_t result = task_name_for_pid(mach_task_self(), pid, &name);
    if (result != KERN_SUCCESS || name == MACH_PORT_NULL) {
        if (name != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), name);
        struct proc_bsdinfo check;
        int code = pp_read_bsd(pid, &check);
        return code == ESRCH ? ESRCH : EACCES;
    }
    memset(token, 0, sizeof(*token));
    mach_msg_type_number_t count = TASK_AUDIT_TOKEN_COUNT;
    result = task_info(name, TASK_AUDIT_TOKEN, (task_info_t)token, &count);
    mach_port_deallocate(mach_task_self(), name);
    if (result != KERN_SUCCESS) return EACCES;
    if (count != TASK_AUDIT_TOKEN_COUNT) return ENOTSUP;
    if (token->val[5] != (uint32_t)pid) return ESTALE;
    return 0;
}

static int pp_bsd_equal(const struct proc_bsdinfo *a,
                        const struct proc_bsdinfo *b) {
    return a->pbi_pid == b->pbi_pid &&
        a->pbi_uid == b->pbi_uid &&
        a->pbi_ruid == b->pbi_ruid &&
        a->pbi_svuid == b->pbi_svuid &&
        a->pbi_flags == b->pbi_flags &&
        memcmp(a->pbi_comm, b->pbi_comm, sizeof(a->pbi_comm)) == 0 &&
        memcmp(a->pbi_name, b->pbi_name, sizeof(a->pbi_name)) == 0 &&
        a->pbi_start_tvsec == b->pbi_start_tvsec &&
        a->pbi_start_tvusec == b->pbi_start_tvusec;
}

int pp_working_directory(int32_t pid, uint64_t started_seconds, char *path, size_t path_size) {
    if (pid <= 0 || !path || !path_size) return EINVAL;
    path[0] = '\0';
    struct proc_bsdinfo before, after;
    int result = pp_read_bsd(pid, &before);
    if (result) return result;
    if (before.pbi_start_tvsec != started_seconds) return ESTALE;

    struct proc_vnodepathinfo dirs = {0};
    int size = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &dirs, sizeof(dirs));
    if (size != (int)sizeof(dirs) || dirs.pvi_cdir.vip_path[0] != '/') return ENOENT;
    result = pp_read_bsd(pid, &after);
    if (result) return result;
    if (!pp_bsd_equal(&before, &after)) return ESTALE;
    size_t length = strnlen(dirs.pvi_cdir.vip_path, sizeof(dirs.pvi_cdir.vip_path));
    if (length == sizeof(dirs.pvi_cdir.vip_path) || length >= path_size) return ENAMETOOLONG;
    memcpy(path, dirs.pvi_cdir.vip_path, length + 1);
    return 0;
}

int pp_read_identity(int32_t pid, PPIdentity *out) {
    if (!out || pid <= 0) return EINVAL;
    memset(out, 0, sizeof(*out));
    struct proc_bsdinfo before, after;
    audit_token_t token_before, token_after;
    int result = pp_read_token(pid, &token_before);
    if (result) return result;
    result = pp_read_bsd(pid, &before);
    if (result) return result;
    errno = 0;
    int size = proc_pidpath(pid, out->executable, sizeof(out->executable));
    if (size <= 0) return errno ? errno : EACCES;
    out->executable[sizeof(out->executable) - 1] = 0;
    result = pp_read_bsd(pid, &after);
    if (result) return result;
    result = pp_read_token(pid, &token_after);
    if (result) return result;
    if (!pp_bsd_equal(&before, &after) ||
        memcmp(&token_before, &token_after, sizeof(token_before)) != 0 ||
        token_after.val[1] != after.pbi_uid || token_after.val[3] != after.pbi_ruid) return ESTALE;
    out->pid = pid;
    out->uid = after.pbi_ruid;
    out->effective_uid = after.pbi_uid;
    out->saved_uid = after.pbi_svuid;
    out->flags = after.pbi_flags;
    out->pid_version = token_after.val[7];
    out->unique_id = 0; /* Reserved API field; public audit token binds generation. */
    out->started_seconds = after.pbi_start_tvsec;
    out->started_microseconds = after.pbi_start_tvusec;
    const char *name = after.pbi_name[0] ? after.pbi_name : after.pbi_comm;
    size_t count = after.pbi_name[0] ? sizeof(after.pbi_name) : sizeof(after.pbi_comm);
    count = strnlen(name, count);
    if (count >= sizeof(out->name)) count = sizeof(out->name) - 1;
    memcpy(out->name, name, count);
    struct passwd record, *entry = NULL;
    char password_buffer[16384];
    if (getpwuid_r(out->uid, &record, password_buffer, sizeof(password_buffer), &entry) == 0 && entry)
        strlcpy(out->owner, entry->pw_name, sizeof(out->owner));
    else
        snprintf(out->owner, sizeof(out->owner), "%u", out->uid);
    return 0;
}

static int pp_is_protected_path(const char *path) {
    return strncmp(path, "/System/", 8) == 0 ||
        strncmp(path, "/usr/libexec/", 13) == 0 ||
        strncmp(path, "/usr/sbin/", 10) == 0 ||
        strncmp(path, "/sbin/", 6) == 0;
}

int pp_signal_identity(const PPIdentity *expected, int signal_number) {
    if (!expected || (signal_number != SIGTERM && signal_number != SIGKILL)) return EINVAL;
    uid_t me = getuid(), effective = geteuid();
    if (!me || me != effective || expected->pid <= 1 || expected->pid == getpid()) return EPERM;
    PPIdentity current;
    int result = pp_read_identity(expected->pid, &current);
    if (result) return result;
    if (current.uid != me || current.effective_uid != me || current.saved_uid != me ||
        (current.flags & PROC_FLAG_SYSTEM) || pp_is_protected_path(current.executable)) return EPERM;
    if (current.pid_version != expected->pid_version || current.unique_id != expected->unique_id ||
        current.started_seconds != expected->started_seconds ||
        current.started_microseconds != expected->started_microseconds ||
        current.uid != expected->uid || current.effective_uid != expected->effective_uid ||
        current.saved_uid != expected->saved_uid ||
        strcmp(current.executable, expected->executable) != 0) return ESTALE;
    audit_token_t token = {{0}};
    token.val[5] = (uint32_t)current.pid;
    token.val[7] = current.pid_version;
    /* The kernel retains the process and verifies pidversion before signaling.
     * The function returns errno directly. Never fall back to kill(pid, sig).
     */
    return proc_signal_with_audittoken(&token, signal_number);
}

static int pp_identifier_safe(const char *value, int jar) {
    size_t length = strnlen(value, 81);
    if (!length || length > 80) return 0;
    for (size_t i = 0; i < length; i++) {
        unsigned char c = (unsigned char)value[i];
        if (!(isalnum(c) && c < 128) && c != '_' && c != '.' && c != '$' && !(jar && c == '-')) return 0;
    }
    if (jar) return length > 4 && strcmp(value + length - 4, ".jar") == 0;
    if (length > 5 && strcmp(value + length - 5, ".java") == 0) return 0;
    return (isalpha((unsigned char)value[0]) && (unsigned char)value[0] < 128) || value[0] == '_' || value[0] == '$';
}

int pp_java_identifier_from_argv(int argc, const char *const *argv,
                                 char *output, size_t output_size) {
    if (!output || output_size == 0) return EINVAL;
    output[0] = 0;
    if (!argv || argc < 2 || argc > 8192) return ENOENT;
    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i];
        if (!arg || strnlen(arg, 65537) > 65536) return ENOENT;
        if (strcmp(arg, "-jar") == 0) {
            if (++i >= argc || !argv[i]) return ENOENT;
            if (strnlen(argv[i], 65537) > 65536) return ENOENT;
            const char *base = strrchr(argv[i], '/');
            base = base ? base + 1 : argv[i];
            if (!pp_identifier_safe(base, 1)) return ENOENT;
            if (strlcpy(output, base, output_size) >= output_size) return ERANGE;
            return 0;
        }
        /* These options consume exactly one operand; none is displayed. */
        const char *operands[] = {"-cp", "-classpath", "--class-path", "-p", "--module-path",
            "--upgrade-module-path", "--add-modules", "--limit-modules", "--add-exports",
            "--add-opens", "--add-reads", "--patch-module", "--enable-native-access", "--source"};
        int consumes = 0;
        for (size_t j = 0; j < sizeof(operands) / sizeof(operands[0]); j++) {
            if (strcmp(arg, operands[j]) == 0) { consumes = 1; break; }
        }
        if (consumes) { if (++i >= argc) return ENOENT; continue; }
        int equals_operand = 0;
        for (size_t j = 0; j < sizeof(operands) / sizeof(operands[0]); j++) {
            size_t length = strlen(operands[j]);
            if (strncmp(arg, operands[j], length) == 0 && arg[length] == '=') { equals_operand = 1; break; }
        }
        if (equals_operand || strncmp(arg, "-D", 2) == 0 || strncmp(arg, "-X", 2) == 0 ||
            strncmp(arg, "-javaagent:", 11) == 0 || strncmp(arg, "-agentlib:", 10) == 0 ||
            strncmp(arg, "-agentpath:", 11) == 0) continue;
        const char *switches[] = {"-server", "-client", "-ea", "-enableassertions", "-da", "-disableassertions",
            "-esa", "-enablesystemassertions", "-dsa", "-disablesystemassertions", "--enable-preview",
            "-verbose", "-verbose:class", "-verbose:gc", "-verbose:jni", "-showversion", "--show-version"};
        int is_switch = 0;
        for (size_t j = 0; j < sizeof(switches) / sizeof(switches[0]); j++) {
            if (strcmp(arg, switches[j]) == 0) { is_switch = 1; break; }
        }
        if (is_switch) continue;
        /* Unknown options, modules, source paths and @argfiles fail closed. */
        if (arg[0] == '-' || arg[0] == '@' || !pp_identifier_safe(arg, 0)) return ENOENT;
        if (strlcpy(output, arg, output_size) >= output_size) return ERANGE;
        return 0;
    }
    return ENOENT;
}

static int pp_free_arguments(char *buffer, size_t size, int result) {
    volatile unsigned char *bytes = (volatile unsigned char *)buffer;
    while (size--) *bytes++ = 0;
    free(buffer);
    return result;
}

int pp_java_app_identifier(int32_t pid, char *output, size_t output_size) {
    if (!output || !output_size) return EINVAL;
    output[0] = 0;
    int mib[] = {CTL_KERN, KERN_PROCARGS2, pid};
    size_t capacity = 1024 * 1024;
    char *buffer = calloc(1, capacity);
    if (!buffer) return ENOMEM;
    size_t size = capacity;
    if (sysctl(mib, 3, buffer, &size, NULL, 0) != 0) {
        int result = errno; return pp_free_arguments(buffer, capacity, result);
    }
    if (size <= sizeof(int) || size > capacity) return pp_free_arguments(buffer, capacity, ENOENT);
    int argc;
    memcpy(&argc, buffer, sizeof(argc));
    if (argc < 1 || argc > 8192) return pp_free_arguments(buffer, capacity, ENOENT);
    char *cursor = buffer + sizeof(int), *end = buffer + size;
    char *nul = memchr(cursor, 0, end - cursor);
    if (!nul) return pp_free_arguments(buffer, capacity, ENOENT);
    cursor = nul + 1;  /* Skip executable path and padding before argv[0]. */
    while (cursor < end && *cursor == 0) cursor++;
    const char **argv = calloc((size_t)argc, sizeof(char *));
    if (!argv) return pp_free_arguments(buffer, capacity, ENOMEM);
    int result = ENOENT;
    for (int i = 0; i < argc; i++) {
        if (cursor >= end) goto finish;
        nul = memchr(cursor, 0, end - cursor);
        if (!nul) goto finish;
        argv[i] = cursor;
        cursor = nul + 1;
    }
    /* Environment bytes after argc argv strings are deliberately never parsed. */
    result = pp_java_identifier_from_argv(argc, argv, output, output_size);
finish:
    free(argv);
    return pp_free_arguments(buffer, capacity, result);
}
