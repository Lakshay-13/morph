#ifndef MORPH_SANDBOX_PROBE_H
#define MORPH_SANDBOX_PROBE_H

#include <sys/types.h>
#include <mach/mach.h>
#include <servers/bootstrap.h>
#include <unistd.h>

// Test-only declarations for Apple's private sandbox decision-query SPI.
// These decision-query helpers do not perform IPC or launch services.
enum morph_sandbox_filter_type {
    MORPH_SANDBOX_FILTER_NONE = 0,
    MORPH_SANDBOX_FILTER_GLOBAL_NAME = 2,
    MORPH_SANDBOX_FILTER_PREFERENCE_DOMAIN = 6,
};

extern const enum morph_sandbox_filter_type SANDBOX_CHECK_NO_REPORT;
int sandbox_check(pid_t, const char *operation, enum morph_sandbox_filter_type, ...);

static inline int morph_sandbox_check_unfiltered(const char *operation) {
    return sandbox_check(getpid(), operation,
        (enum morph_sandbox_filter_type)(MORPH_SANDBOX_FILTER_NONE | SANDBOX_CHECK_NO_REPORT));
}

static inline int morph_sandbox_check_global_name(const char *operation, const char *name) {
    return sandbox_check(getpid(), operation,
        (enum morph_sandbox_filter_type)(MORPH_SANDBOX_FILTER_GLOBAL_NAME | SANDBOX_CHECK_NO_REPORT), name);
}

static inline int morph_sandbox_check_preference_domain(const char *operation, const char *domain) {
    return sandbox_check(getpid(), operation,
        (enum morph_sandbox_filter_type)(MORPH_SANDBOX_FILTER_PREFERENCE_DOMAIN | SANDBOX_CHECK_NO_REPORT), domain);
}

// Actively checks a Mach service lookup and releases any returned send right.
// Callers should first confirm the service is available outside the sandbox.
static inline kern_return_t morph_sandbox_attempt_mach_lookup(const char *service_name) {
    mach_port_t service_port = MACH_PORT_NULL;
    kern_return_t status = bootstrap_look_up(bootstrap_port, service_name, &service_port);
    if (MACH_PORT_VALID(service_port)) {
        (void)mach_port_deallocate(mach_task_self(), service_port);
    }
    return status;
}

static inline pid_t morph_sandbox_attempt_fork(void) {
    return fork();
}

#endif
