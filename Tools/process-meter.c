/*
 * Targeted macOS process-cost sampler. No process enumeration or watts estimate.
 * Build: clang -O2 -Wall -Wextra -Werror process-meter.c -o process-meter
 * Usage: process-meter --duration 60 --interval 5 --pids 123,456 --output run.csv
 * CPU 100% means one logical core. rusage CPU counters use Mach absolute ticks;
 * conversion was checked against a controlled busy process and top on this Mac.
 * Missing/denied/exited/reused PIDs produce empty measurements, never fake zeros.
 */
#include <errno.h>
#include <getopt.h>
#include <inttypes.h>
#include <limits.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>

#define MAX_TARGETS 128

typedef struct {
    uint64_t stamp;
    struct rusage_info_v0 usage;
} Snapshot;

typedef struct {
    pid_t pid;
    Snapshot previous;
    uint64_t identity;
    bool identified;
    bool previous_valid;
    bool terminal;
    const char *terminal_status;
    int terminal_errno;
} Target;

static double seconds_per_tick;

static int snapshot(pid_t pid, Snapshot *out)
{
    memset(out, 0, sizeof(*out));
    uint64_t before = mach_absolute_time();
    if (proc_pid_rusage(pid, RUSAGE_INFO_V0,
                        (rusage_info_t *)&out->usage) != 0)
        return -1;
    uint64_t after = mach_absolute_time();
    out->stamp = before + (after - before) / 2;
    return 0;
}

static void usage(FILE *out)
{
    fprintf(out, "Usage: process-meter --duration SECONDS --interval SECONDS "
                 "--pids PID,PID [--output FILE.csv]\n"
                 "Duration: 0.1..86400; interval: 0.1..3600 seconds.\n"
                 "Default output: stdout. Existing output files are not overwritten.\n"
                 "Only explicitly listed PIDs are read; no sudo is required for "
                 "ordinary same-user targets.\n");
}

static bool number(const char *text, double min, double max, double *out)
{
    char *end;
    errno = 0;
    double value = strtod(text, &end);
    if (errno || end == text || *end || !isfinite(value) || value < min || value > max)
        return false;
    *out = value;
    return true;
}

static size_t parse_pids(const char *text, Target *targets)
{
    size_t count = 0;
    const char *cursor = text;
    while (*cursor) {
        char *end;
        errno = 0;
        long pid = strtol(cursor, &end, 10);
        if (errno || end == cursor || pid <= 0 || pid > INT_MAX ||
            (*end != ',' && *end != '\0') || count == MAX_TARGETS)
            return 0;
        for (size_t i = 0; i < count; i++)
            if (targets[i].pid == pid) return 0;
        targets[count++].pid = (pid_t)pid;
        if (!*end) return count;
        cursor = end + 1;
        if (!*cursor) return 0;
    }
    return 0;
}

static void empty_row(FILE *out, double elapsed, Target *target,
                      const char *status, int error)
{
    fprintf(out, "%.6f,%d,%s,%d,,,,,,,,\n", elapsed, target->pid, status, error);
}

static void sample_target(FILE *out, Target *target, uint64_t begin)
{
    double elapsed = (mach_absolute_time() - begin) * seconds_per_tick;
    if (target->terminal) {
        empty_row(out, elapsed, target, target->terminal_status, target->terminal_errno);
        return;
    }
    Snapshot current;
    if (snapshot(target->pid, &current) != 0) {
        int error = errno;
        const char *status = error == ESRCH ? "missing_exited" :
            (error == EPERM || error == EACCES ? "missing_permission" : "missing_error");
        target->previous_valid = false;
        /* Never adopt an unrelated process that later acquires a missing PID. */
        if (!target->identified || error == ESRCH) {
            target->terminal = true;
            target->terminal_status = status;
            target->terminal_errno = error;
        }
        empty_row(out, elapsed, target, status, error);
        return;
    }
    elapsed = (current.stamp - begin) * seconds_per_tick;
    if (current.usage.ri_proc_exit_abstime != 0) {
        target->terminal = true;
        target->terminal_status = "missing_exited";
        target->terminal_errno = 0;
        empty_row(out, elapsed, target, target->terminal_status, 0);
        return;
    }
    if (target->identified && target->identity != current.usage.ri_proc_start_abstime) {
        target->terminal = true;
        target->terminal_status = "missing_pid_reused";
        target->terminal_errno = 0;
        empty_row(out, elapsed, target, target->terminal_status, 0);
        return;
    }
    const char *baseline_status = target->identified ? "baseline_resumed" : "baseline";
    target->identified = true;
    target->identity = current.usage.ri_proc_start_abstime;
    const struct rusage_info_v0 *a = &target->previous.usage;
    const struct rusage_info_v0 *b = &current.usage;
    if (target->previous_valid &&
        (current.stamp <= target->previous.stamp || b->ri_user_time < a->ri_user_time ||
         b->ri_system_time < a->ri_system_time ||
         b->ri_interrupt_wkups < a->ri_interrupt_wkups ||
         b->ri_pkg_idle_wkups < a->ri_pkg_idle_wkups)) {
        baseline_status = "baseline_counter_reset";
        target->previous_valid = false;
    }
    if (!target->previous_valid) {
        fprintf(out, "%.6f,%d,%s,0,,,,,,,,%" PRIu64 "\n",
                elapsed, target->pid, baseline_status, b->ri_resident_size);
    } else {
        double interval = (current.stamp - target->previous.stamp) * seconds_per_tick;
        double cpu = ((double)(b->ri_user_time - a->ri_user_time) +
                      (double)(b->ri_system_time - a->ri_system_time)) * seconds_per_tick;
        uint64_t interrupts = b->ri_interrupt_wkups - a->ri_interrupt_wkups;
        uint64_t idle = b->ri_pkg_idle_wkups - a->ri_pkg_idle_wkups;
        fprintf(out, "%.6f,%d,ok,0,%.6f,%.9f,%.6f,%" PRIu64 ",%.6f,%" PRIu64
                     ",%.6f,%" PRIu64 "\n",
                elapsed, target->pid, interval, cpu, 100.0 * cpu / interval,
                interrupts, interrupts / interval, idle, idle / interval, b->ri_resident_size);
    }
    target->previous = current;
    target->previous_valid = true;
}

static int sleep_until(uint64_t begin, double elapsed)
{
    for (;;) {
        double remaining = elapsed - (mach_absolute_time() - begin) * seconds_per_tick;
        if (remaining <= 0) return 0;
        struct timespec request = { .tv_sec = (time_t)remaining };
        request.tv_nsec = (long)((remaining - request.tv_sec) * 1e9);
        if (nanosleep(&request, NULL) != 0 && errno != EINTR) return -1;
    }
}

int main(int argc, char **argv)
{
    double duration = 0, interval = 0;
    const char *pids = NULL, *output = NULL;
    static const struct option options[] = {
        {"duration", required_argument, NULL, 'd'},
        {"interval", required_argument, NULL, 'i'},
        {"pids", required_argument, NULL, 'p'},
        {"output", required_argument, NULL, 'o'},
        {"help", no_argument, NULL, 'h'}, {NULL, 0, NULL, 0}
    };
    int option;
    while ((option = getopt_long(argc, argv, "d:i:p:o:h", options, NULL)) != -1) {
        switch (option) {
        case 'd': if (!number(optarg, 0.1, 86400, &duration)) goto invalid; break;
        case 'i': if (!number(optarg, 0.1, 3600, &interval)) goto invalid; break;
        case 'p': pids = optarg; break;
        case 'o': output = optarg; break;
        case 'h': usage(stdout); return 0;
        default: goto invalid;
        }
    }
    if (optind != argc || !duration || !interval || !pids) goto invalid;
    Target targets[MAX_TARGETS] = {0};
    size_t count = parse_pids(pids, targets);
    if (!count) goto invalid;
    mach_timebase_info_data_t timebase;
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || !timebase.denom) {
        fprintf(stderr, "Unable to obtain Mach clock conversion.\n"); return 1;
    }
    seconds_per_tick = (double)timebase.numer / timebase.denom / 1e9;
    FILE *out = output ? fopen(output, "wx") : stdout;
    if (!out) { perror("output"); return 1; }
    fprintf(out, "elapsed_seconds,pid,status,errno,sample_seconds,cpu_seconds,cpu_percent,"
                 "interrupt_wakeups,interrupt_wakeups_per_second,pkg_idle_wakeups,"
                 "pkg_idle_wakeups_per_second,rss_bytes\n");
    uint64_t begin = mach_absolute_time();
    double deadline = 0;
    for (;;) {
        if (sleep_until(begin, deadline) != 0) { perror("nanosleep"); return 1; }
        for (size_t i = 0; i < count; i++) sample_target(out, &targets[i], begin);
        if (fflush(out) != 0) { perror("output"); return 1; }
        if (deadline >= duration) break;
        /* Skip missed deadlines rather than burst-sampling after a delay. */
        double elapsed = (mach_absolute_time() - begin) * seconds_per_tick;
        deadline = fmin(duration, (floor(elapsed / interval) + 1) * interval);
    }
    if (output && fclose(out) != 0) { perror("output"); return 1; }
    return 0;
invalid:
    usage(stderr);
    return 2;
}
