#include "../Sources/ProcessBridge.h"
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int passed = 0, failed = 0;
static void check(const char *name, int condition) {
    printf("%s %s\n", condition ? "PASS" : "FAIL", name);
    if (condition) passed++; else failed++;
}

int main(void) {
    char output[256];
    const char *jar[] = {"java", "-Ddb.password=TEST_ONLY_SECRET", "-Xmx256m",
                         "-javaagent:/private/TEST_ONLY_SECRET/agent.jar", "-jar",
                         "/private/TEST_ONLY_SECRET/sample-api.jar", "--api-token", "TEST_ONLY_SECRET"};
    int rc = pp_java_identifier_from_argv(8, jar, output, sizeof(output));
    check("java_jar_only_safe_basename", rc == 0 && strcmp(output, "sample-api.jar") == 0);

    const char *main_class[] = {"java", "-classpath", "/private/TEST_ONLY_SECRET/classes",
                                "-Dapi.token=TEST_ONLY_SECRET", "com.example.SampleApi",
                                "--password", "TEST_ONLY_SECRET"};
    rc = pp_java_identifier_from_argv(7, main_class, output, sizeof(output));
    check("java_class_skips_secret_jvm_and_app_arguments", rc == 0 && strcmp(output, "com.example.SampleApi") == 0);

    const char *unknown[] = {"java", "--password", "TEST_ONLY_SECRET", "com.example.SampleApi"};
    rc = pp_java_identifier_from_argv(4, unknown, output, sizeof(output));
    check("java_unknown_options_fail_closed", rc == ENOENT && output[0] == 0);

    const char *invalid_jar[] = {"java", "-jar", "/tmp/sample-api.jar?token=TEST_ONLY_SECRET"};
    rc = pp_java_identifier_from_argv(3, invalid_jar, output, sizeof(output));
    check("java_identifier_rejects_query_secret", rc == ENOENT && output[0] == 0);

    const char *argfile[] = {"java", "@/private/TEST_ONLY_SECRET/options.txt"};
    rc = pp_java_identifier_from_argv(2, argfile, output, sizeof(output));
    check("java_argfile_is_not_displayed_or_opened", rc == ENOENT && output[0] == 0);

    const char *module[] = {"java", "--module-path", "/private/TEST_ONLY_SECRET/modules", "-m", "app/com.example.Main"};
    rc = pp_java_identifier_from_argv(5, module, output, sizeof(output));
    check("java_module_launch_without_safe_identifier_fails_closed", rc == ENOENT && output[0] == 0);

    const char *missing[] = {"java", "-jar"};
    rc = pp_java_identifier_from_argv(2, missing, output, sizeof(output));
    check("java_missing_operand_fails_closed", rc == ENOENT && output[0] == 0);

    const char *normal[] = {"java", "com.example.Main"};
    rc = pp_java_identifier_from_argv(2, normal, output, 4);
    check("java_small_output_buffer_reports_failure", rc == ERANGE);

    PPIdentity identity;
    memset(&identity, 0, sizeof(identity));
    identity.pid = getpid();
    rc = pp_signal_identity(&identity, SIGTERM);
    check("bridge_refuses_self_before_signal", rc == EPERM);
    identity.pid = 1;
    rc = pp_signal_identity(&identity, SIGKILL);
    check("bridge_refuses_pid_one_before_signal", rc == EPERM);
    rc = pp_signal_identity(&identity, SIGUSR1);
    check("bridge_invalid_signal_reports_failure_without_signaling", rc == EINVAL);
    rc = pp_signal_identity(NULL, SIGTERM);
    check("bridge_missing_identity_reports_failure_without_signaling", rc == EINVAL);

    printf("RESULT %d/%d passed\n", passed, passed + failed);
    return failed == 0 ? 0 : 1;
}
