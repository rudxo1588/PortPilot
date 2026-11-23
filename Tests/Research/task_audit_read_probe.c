// Read-only public API probe. Never signals any process.
#include <errno.h>
#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>

static kern_return_t read_token(pid_t pid, audit_token_t *token) {
    mach_port_t name = MACH_PORT_NULL;
    kern_return_t result = task_name_for_pid(mach_task_self(), pid, &name);
    if (result != KERN_SUCCESS) return result;
    mach_msg_type_number_t count = TASK_AUDIT_TOKEN_COUNT;
    result = task_info(name, TASK_AUDIT_TOKEN, (task_info_t)token, &count);
    mach_port_deallocate(mach_task_self(), name);
    if (result == KERN_SUCCESS && count != TASK_AUDIT_TOKEN_COUNT) return KERN_FAILURE;
    return result;
}

int main(int argc, char **argv) {
    int failures = 0;
    for (int i = 1; i < argc; i++) {
        char *end;
        errno = 0;
        long value = strtol(argv[i], &end, 10);
        if (errno || *end || value <= 0 || value > INT32_MAX) return 2;
        audit_token_t token = {{0}};
        kern_return_t result = read_token((pid_t)value, &token);
        printf("read-only pid=%ld result=%d token_pid=%u pid_matches=%s version=%u effective_uid=%u\n",
               value, result, token.val[5], token.val[5] == value ? "yes" : "no", token.val[7], token.val[1]);
        if (result != KERN_SUCCESS || token.val[5] != value) failures++;
    }
    return failures ? 1 : 0;
}
