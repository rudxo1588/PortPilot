#ifndef PORTPILOT_PROCESS_BRIDGE_H
#define PORTPILOT_PROCESS_BRIDGE_H
#include <stdint.h>
#include <stddef.h>

typedef struct {
    int32_t pid;
    uint32_t uid;
    uint32_t effective_uid;
    uint32_t saved_uid;
    uint32_t flags;
    uint32_t pid_version;
    uint64_t unique_id;
    uint64_t started_seconds;
    uint64_t started_microseconds;
    char name[64];
    char executable[4096];
    char owner[256];
} PPIdentity;

/* All functions return an errno value, never -1. No function logs argv/env. */
int pp_working_directory(int32_t pid, uint64_t started_seconds, char *path, size_t path_size);
int pp_read_identity(int32_t pid, PPIdentity *identity);
int pp_signal_identity(const PPIdentity *expected, int signal_number);
int pp_java_app_identifier(int32_t pid, char *output, size_t output_size);
int pp_java_identifier_from_argv(int argc, const char *const *argv,
                                 char *output, size_t output_size);
#endif
