/**
 * Copyright (c) 2026, Lothar Maisenbacher
 *
 * All rights reserved.
 *
 * @brief The lock monitor daemon (lockbox-monitor).
 *
 * Polls the FPGA's lock and hold flags of the four PID controllers every
 * millisecond (one register read), runs the lock-drop bookkeeping of
 * lockstat.c for each, and publishes the result in the shared-memory block
 * of lockbox_monitor.h, which liblockbox reads for the SCPI server and the
 * web interface. A second thread owns the scope block and measures the
 * fast inputs' noise: buffers of samples averaged over the decimation are
 * pooled into windows of about a second, and mean, standard deviation,
 * minimum and maximum of each window go into the same block.
 *
 * The daemon joins a running lockbox with rp_Attach() - it never resets
 * anything. Run it as a systemd service (systemd/lockbox-monitor.service),
 * which gives it its real-time priority.
 */

#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>

#include "redpitaya/lockbox.h"
#include "redpitaya/lockbox_monitor.h"
#include "lockstat.h"

#define NS_PER_S 1000000000ULL
#define NS_PER_MS 1000000ULL
/* The ADC's sample period */
#define ADC_PERIOD_NS 8ULL
/* Length of one statistics window at least (buffers are pooled until it is reached) */
#define STATS_WINDOW_NS NS_PER_S
/* Default path of the daemon's own settings file */
#define DEFAULT_CONF_PATH "/home/redpitaya/lockbox-monitor.conf"

static volatile sig_atomic_t stop_requested = 0;

struct options {
    double period_ms;
    double merge_ms;
    double grace_s;
    uint32_t stats_decimation;
    bool stats;
    const char *conf_path;
};

/* The statistics thread hands each finished window to the poll thread
 * through this staging area (the poll thread owns the published block) */
struct stats_staging {
    pthread_mutex_t lock;
    struct lockbox_monitor_input inputs[LOCKBOX_MONITOR_INPUTS];
    bool fresh;
};

static struct lockbox_monitor *shm = NULL;
static struct lockbox_monitor work;
static struct stats_staging staging = { .lock = PTHREAD_MUTEX_INITIALIZER };
static struct options opts;

static void on_signal(int signum)
{
    (void)signum;
    stop_requested = 1;
}

static uint64_t monotonic_ns()
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * NS_PER_S + (uint64_t)ts.tv_nsec;
}

static void sleep_ns(uint64_t ns)
{
    struct timespec ts = { .tv_sec = ns / NS_PER_S, .tv_nsec = ns % NS_PER_S };
    while (nanosleep(&ts, &ts) == -1 && errno == EINTR && !stop_requested)
        ;
}

static void usage(const char *argv0)
{
    fprintf(stderr,
            "Usage: %s [options]\n"
            "  --period-ms <ms>         poll period (default 1)\n"
            "  --merge-ms <ms>          lock time that closes a drop (default 10)\n"
            "  --grace-s <s>            startup time during which nothing is counted (default 2)\n"
            "  --stats-decimation <n>   scope decimation of the input statistics:\n"
            "                           64, 1024, 8192 or 65536 (default 1024; the settings\n"
            "                           file overrides this default)\n"
            "  --no-stats               do not measure the input statistics\n"
            "  --conf <path>            settings file (default %s)\n",
            argv0, DEFAULT_CONF_PATH);
}

static bool valid_decimation(uint32_t dec)
{
    return dec == 64 || dec == 1024 || dec == 8192 || dec == 65536;
}

/* The settings file: one key=value per line; only stats_decimation so far */
static void load_conf(struct options *o)
{
    FILE *f = fopen(o->conf_path, "r");
    if (!f)
        return;
    char line[128];
    while (fgets(line, sizeof(line), f)) {
        unsigned long value;
        if (sscanf(line, "stats_decimation=%lu", &value) == 1) {
            if (valid_decimation((uint32_t)value))
                o->stats_decimation = (uint32_t)value;
            else
                syslog(LOG_WARNING, "%s: ignoring stats_decimation=%lu", o->conf_path, value);
        }
    }
    fclose(f);
}

static void save_conf(const struct options *o)
{
    char tmp[512];
    snprintf(tmp, sizeof(tmp), "%s.tmp", o->conf_path);
    FILE *f = fopen(tmp, "w");
    if (!f) {
        syslog(LOG_WARNING, "cannot write %s: %s", tmp, strerror(errno));
        return;
    }
    fprintf(f, "stats_decimation=%u\n", o->stats_decimation);
    fclose(f);
    if (rename(tmp, o->conf_path) != 0)
        syslog(LOG_WARNING, "cannot replace %s: %s", o->conf_path, strerror(errno));
}

static int parse_options(int argc, char *argv[], struct options *o)
{
    static const struct option longopts[] = {
        { "period-ms", required_argument, NULL, 'p' },
        { "merge-ms", required_argument, NULL, 'm' },
        { "grace-s", required_argument, NULL, 'g' },
        { "stats-decimation", required_argument, NULL, 'd' },
        { "no-stats", no_argument, NULL, 'n' },
        { "conf", required_argument, NULL, 'c' },
        { "help", no_argument, NULL, 'h' },
        { NULL, 0, NULL, 0 }
    };
    o->period_ms = 1.0;
    o->merge_ms = 10.0;
    o->grace_s = 2.0;
    o->stats_decimation = 1024;
    o->stats = true;
    o->conf_path = DEFAULT_CONF_PATH;
    bool decimation_given = false;
    int c;
    while ((c = getopt_long(argc, argv, "h", longopts, NULL)) != -1) {
        switch (c) {
        case 'p': o->period_ms = atof(optarg); break;
        case 'm': o->merge_ms = atof(optarg); break;
        case 'g': o->grace_s = atof(optarg); break;
        case 'd':
            o->stats_decimation = (uint32_t)strtoul(optarg, NULL, 10);
            decimation_given = true;
            break;
        case 'n': o->stats = false; break;
        case 'c': o->conf_path = optarg; break;
        case 'h': usage(argv[0]); return 1;
        default: usage(argv[0]); return -1;
        }
    }
    if (o->period_ms <= 0 || o->merge_ms < 0 || o->grace_s < 0 || !valid_decimation(o->stats_decimation)) {
        usage(argv[0]);
        return -1;
    }
    /* The settings file holds what a web page or SCPI client selected */
    if (!decimation_given)
        load_conf(o);
    return 0;
}

static int create_block()
{
    int fd = shm_open(LOCKBOX_MONITOR_SHM, O_CREAT | O_RDWR, 0644);
    if (fd == -1) {
        syslog(LOG_ERR, "shm_open(%s): %s", LOCKBOX_MONITOR_SHM, strerror(errno));
        return -1;
    }
    if (ftruncate(fd, sizeof(struct lockbox_monitor)) != 0) {
        syslog(LOG_ERR, "ftruncate: %s", strerror(errno));
        close(fd);
        return -1;
    }
    void *map = mmap(NULL, sizeof(struct lockbox_monitor), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (map == MAP_FAILED) {
        syslog(LOG_ERR, "mmap: %s", strerror(errno));
        return -1;
    }
    shm = map;
    memset(shm, 0, sizeof(*shm));
    return 0;
}

/* Publish the working copy: the block is a seqlock */
static void publish()
{
    uint32_t seq = shm->seq;
    __atomic_store_n(&shm->seq, seq + 1, __ATOMIC_RELEASE);
    __atomic_thread_fence(__ATOMIC_RELEASE);
    /* Everything but the sequence word and the consumers' request word */
    memcpy((char *)shm + offsetof(struct lockbox_monitor, layout),
           (const char *)&work + offsetof(struct lockbox_monitor, layout),
           offsetof(struct lockbox_monitor, stats_decimation_request)
               - offsetof(struct lockbox_monitor, layout));
    __atomic_thread_fence(__ATOMIC_RELEASE);
    __atomic_store_n(&shm->seq, seq + 2, __ATOMIC_RELEASE);
}

/*
 * Input statistics thread
 */

static rp_acq_decimation_t decimation_enum(uint32_t dec)
{
    switch (dec) {
    case 64: return RP_DEC_64;
    case 8192: return RP_DEC_8192;
    case 65536: return RP_DEC_65536;
    default: return RP_DEC_1024;
    }
}

struct accumulator {
    double sum, sumsq, min, max;
    uint64_t n;
};

static void accumulator_reset(struct accumulator *a)
{
    a->sum = a->sumsq = 0.0;
    a->min = INFINITY;
    a->max = -INFINITY;
    a->n = 0;
}

static void accumulate(struct accumulator *a, const float *buf, uint32_t n)
{
    for (uint32_t i = 0; i < n; i++) {
        double v = buf[i];
        a->sum += v;
        a->sumsq += v * v;
        if (v < a->min) a->min = v;
        if (v > a->max) a->max = v;
    }
    a->n += n;
}

static void stage_decimation(uint32_t dec)
{
    pthread_mutex_lock(&staging.lock);
    for (int ch = 0; ch < LOCKBOX_MONITOR_INPUTS; ch++)
        staging.inputs[ch].decimation = dec;
    staging.fresh = true;
    pthread_mutex_unlock(&staging.lock);
}

static void *stats_thread(void *arg)
{
    (void)arg;
    static float buf[ADC_BUFFER_SIZE];
    struct accumulator acc[LOCKBOX_MONITOR_INPUTS];
    uint32_t dec = 0;
    uint64_t buffer_ns = 0, buffers_per_window = 0, buffers = 0;

    while (!stop_requested) {
        /* A pending request, or the first pass, (re)configures the scope */
        uint32_t request = __atomic_exchange_n(&shm->stats_decimation_request, 0, __ATOMIC_ACQ_REL);
        if (request && !valid_decimation(request)) {
            syslog(LOG_WARNING, "ignoring stats decimation request %u", request);
            request = 0;
        }
        if (request && request != dec) {
            opts.stats_decimation = request;
            save_conf(&opts);
            syslog(LOG_INFO, "input statistics decimation %u", request);
        }
        if (dec == 0 || request) {
            dec = request ? request : opts.stats_decimation;
            rp_AcqSetTriggerSrc(RP_TRIG_SRC_DISABLED);
            rp_AcqSetAveraging(true);
            rp_AcqSetDecimation(decimation_enum(dec));
            buffer_ns = (uint64_t)ADC_BUFFER_SIZE * dec * ADC_PERIOD_NS;
            buffers_per_window = (STATS_WINDOW_NS + buffer_ns - 1) / buffer_ns;
            for (int ch = 0; ch < LOCKBOX_MONITOR_INPUTS; ch++)
                accumulator_reset(&acc[ch]);
            buffers = 0;
            stage_decimation(dec);
        }

        /* One buffer: the scope writes for one full turn of its ring */
        rp_AcqStart();
        sleep_ns(buffer_ns + buffer_ns / 10 + 5 * NS_PER_MS);
        if (stop_requested)
            break;
        rp_AcqStop();
        for (int ch = 0; ch < LOCKBOX_MONITOR_INPUTS; ch++) {
            uint32_t size = ADC_BUFFER_SIZE;
            if (rp_AcqGetOldestDataV((rp_channel_t)ch, &size, buf) == RP_OK)
                accumulate(&acc[ch], buf, size);
        }
        buffers++;
        if (buffers < buffers_per_window)
            continue;

        /* The window is complete */
        uint64_t now = monotonic_ns();
        pthread_mutex_lock(&staging.lock);
        for (int ch = 0; ch < LOCKBOX_MONITOR_INPUTS; ch++) {
            struct lockbox_monitor_input *in = &staging.inputs[ch];
            double n = (double)acc[ch].n;
            double mean = n > 0 ? acc[ch].sum / n : 0.0;
            double var = n > 1 ? (acc[ch].sumsq / n - mean * mean) * n / (n - 1) : 0.0;
            in->mean_v = mean;
            in->sd_v = var > 0 ? sqrt(var) : 0.0;
            in->min_v = acc[ch].n ? acc[ch].min : 0.0;
            in->max_v = acc[ch].n ? acc[ch].max : 0.0;
            in->window_s = (double)(buffers * buffer_ns) / (double)NS_PER_S;
            in->n_samples = acc[ch].n;
            in->decimation = dec;
            in->updated_ns = now;
            accumulator_reset(&acc[ch]);
        }
        staging.fresh = true;
        pthread_mutex_unlock(&staging.lock);
        buffers = 0;
    }
    rp_AcqStop();
    return NULL;
}

/* The poll thread takes a finished window when one is staged; it never
 * waits for the statistics thread */
static void take_stats()
{
    if (pthread_mutex_trylock(&staging.lock) != 0)
        return;
    if (staging.fresh) {
        memcpy(work.inputs, staging.inputs, sizeof(work.inputs));
        staging.fresh = false;
    }
    pthread_mutex_unlock(&staging.lock);
}

/*
 * Main
 */

int main(int argc, char *argv[])
{
    openlog("lockbox-monitor", LOG_CONS | LOG_PID | LOG_NDELAY, LOG_LOCAL1);
    setlogmask(LOG_UPTO(LOG_INFO));

    int parsed = parse_options(argc, argv, &opts);
    if (parsed != 0)
        return parsed > 0 ? EXIT_SUCCESS : EXIT_FAILURE;

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = on_signal;
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGINT, &action, NULL);

    int result = rp_Attach();
    if (result != RP_OK) {
        syslog(LOG_ERR, "rp_Attach failed: %s", rp_GetError(result));
        return EXIT_FAILURE;
    }
    if (create_block() != 0)
        return EXIT_FAILURE;
    if (mlockall(MCL_CURRENT | MCL_FUTURE) != 0)
        syslog(LOG_WARNING, "mlockall: %s", strerror(errno));

    uint64_t period_ns = (uint64_t)(opts.period_ms * (double)NS_PER_MS);
    uint64_t merge_ns = (uint64_t)(opts.merge_ms * (double)NS_PER_MS);
    uint64_t grace_ns = (uint64_t)(opts.grace_s * (double)NS_PER_S);

    memset(&work, 0, sizeof(work));
    work.layout = LOCKBOX_MONITOR_LAYOUT;
    work.pid = (uint32_t)getpid();
    work.stats_enabled = opts.stats ? 1 : 0;
    work.poll_period_ns = period_ns;
    work.merge_ns = merge_ns;
    work.grace_ns = grace_ns;

    /* The first poll is the baseline */
    uint8_t locked, held;
    rp_PIDGetLockHoldBits(&locked, &held);
    uint64_t now = monotonic_ns();
    work.start_ns = now;
    work.last_poll_ns = now;
    for (int i = 0; i < LOCKBOX_MONITOR_PIDS; i++)
        lockstat_init(&work.pids[i], now, (locked >> i) & 1, (held >> i) & 1);
    publish();

    pthread_t stats;
    bool stats_running = false;
    if (opts.stats) {
        if (pthread_create(&stats, NULL, stats_thread, NULL) == 0)
            stats_running = true;
        else
            syslog(LOG_ERR, "cannot start the statistics thread: %s", strerror(errno));
    }

    syslog(LOG_NOTICE, "lockbox-monitor started: period %.3g ms, merge %.3g ms, grace %.3g s, "
           "statistics %s (decimation %u)", opts.period_ms, opts.merge_ms, opts.grace_s,
           opts.stats ? "on" : "off", opts.stats_decimation);

    uint64_t next = now + period_ns;
    while (!stop_requested) {
        struct timespec ts = { .tv_sec = next / NS_PER_S, .tv_nsec = next % NS_PER_S };
        while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &ts, NULL) == EINTR && !stop_requested)
            ;
        if (stop_requested)
            break;

        rp_PIDGetLockHoldBits(&locked, &held);
        now = monotonic_ns();
        uint64_t gap = now - work.last_poll_ns;
        if (gap > work.max_gap_ns)
            work.max_gap_ns = gap;
        if (gap > 2 * period_ns)
            work.late_polls++;
        int counting = now - work.start_ns >= grace_ns;
        for (int i = 0; i < LOCKBOX_MONITOR_PIDS; i++)
            lockstat_poll(&work.pids[i], now, (locked >> i) & 1, (held >> i) & 1, merge_ns, counting);
        work.last_poll_ns = now;
        work.polls++;
        take_stats();
        publish();

        next += period_ns;
        /* After a long stall, resume from now instead of catching up */
        if (next < now)
            next = now + period_ns;
    }

    syslog(LOG_NOTICE, "lockbox-monitor stopping");
    if (stats_running) {
        /* Wake the statistics thread out of its buffer sleep */
        pthread_kill(stats, SIGTERM);
        pthread_join(stats, NULL);
    }
    /* A clean exit: readers see pid 0, and the block is gone */
    work.pid = 0;
    publish();
    shm_unlink(LOCKBOX_MONITOR_SHM);
    munmap(shm, sizeof(*shm));
    rp_Release();
    closelog();
    return EXIT_SUCCESS;
}
