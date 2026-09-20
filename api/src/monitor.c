/**
 * Copyright (c) 2026, Lothar Maisenbacher
 *
 * All rights reserved.
 *
 * @brief Reader of the lockbox monitor's shared-memory block (see monitor.h).
 *
 * The block is a seqlock written by the lockbox-monitor daemon at its poll
 * rate. A reader maps it once and copies it under a sequence check. The
 * daemon unlinks and re-creates the block when it restarts, so a mapping
 * can outlive its block: a snapshot whose last poll is older than
 * LOCKBOX_MONITOR_STALE_NS, or whose daemon pid is 0 (clean exit), drops
 * the mapping and maps the block anew before giving up with RP_EMON.
 */

#include <fcntl.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sched.h>
#include <sys/mman.h>
#include <sys/stat.h>

#include "monitor.h"

_Static_assert(sizeof(struct lockbox_monitor) == LOCKBOX_MONITOR_SIZE,
               "lockbox_monitor layout");
_Static_assert(sizeof(struct lockbox_monitor_input) == LOCKBOX_MONITOR_INPUT_SIZE,
               "lockbox_monitor_input layout");

static volatile struct lockbox_monitor *block = NULL;

#define NS_PER_S 1000000000.0

static uint64_t monotonic_ns()
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

static int mon_Map()
{
    int fd = shm_open(LOCKBOX_MONITOR_SHM, O_RDONLY, 0);
    if (fd == -1)
        return RP_EMON;
    struct stat st;
    if (fstat(fd, &st) != 0 || (size_t)st.st_size < sizeof(struct lockbox_monitor)) {
        close(fd);
        return RP_EMON;
    }
    void *map = mmap(NULL, sizeof(struct lockbox_monitor), PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    if (map == MAP_FAILED)
        return RP_EMON;
    if (((volatile struct lockbox_monitor *)map)->layout != LOCKBOX_MONITOR_LAYOUT) {
        munmap(map, sizeof(struct lockbox_monitor));
        return RP_EMON;
    }
    block = map;
    return RP_OK;
}

void mon_Release()
{
    if (block) {
        munmap((void *)block, sizeof(struct lockbox_monitor));
        block = NULL;
    }
}

/* One seqlock read of the mapped block */
static int mon_Copy(struct lockbox_monitor *out)
{
    for (int tries = 0; tries < 1000; tries++) {
        uint32_t s1 = __atomic_load_n(&block->seq, __ATOMIC_ACQUIRE);
        if (s1 & 1) {
            sched_yield();
            continue;
        }
        memcpy(out, (const void *)block, sizeof(*out));
        __atomic_thread_fence(__ATOMIC_ACQUIRE);
        uint32_t s2 = __atomic_load_n(&block->seq, __ATOMIC_ACQUIRE);
        if (s1 == s2)
            return RP_OK;
    }
    return RP_EMON;
}

static bool mon_Alive(const struct lockbox_monitor *m, uint64_t now_ns)
{
    return m->pid != 0 && m->last_poll_ns != 0 && now_ns >= m->last_poll_ns
           && now_ns - m->last_poll_ns <= LOCKBOX_MONITOR_STALE_NS;
}

int mon_Snapshot(struct lockbox_monitor *out, uint64_t *now_ns)
{
    for (int attempt = 0; attempt < 2; attempt++) {
        if (!block && mon_Map() != RP_OK)
            return RP_EMON;
        if (mon_Copy(out) != RP_OK)
            return RP_EMON;
        *now_ns = monotonic_ns();
        if (mon_Alive(out, *now_ns))
            return RP_OK;
        /* Dead or replaced: map afresh once */
        mon_Release();
    }
    return RP_EMON;
}

static double age_s(uint64_t now_ns, uint64_t then_ns)
{
    return then_ns ? (double)(now_ns - then_ns) / NS_PER_S : -1.0;
}

int mon_GetPID(rp_pid_t pid, rp_pid_monitor_t *out)
{
    struct lockbox_monitor m;
    uint64_t now;
    if (pid > RP_PID_22)
        return RP_EPN;
    int result = mon_Snapshot(&m, &now);
    if (result != RP_OK)
        return result;
    const struct lockbox_monitor_pid *p = &m.pids[pid];

    out->locked = p->locked != 0;
    out->lock_age_s = age_s(now, p->state_since_ns);
    out->servo_on = p->servo_since_ns != 0;
    out->servo_age_s = age_s(now, p->servo_since_ns);
    out->unlocks_total = p->unlock_count;
    out->unlocked_total_s = (double)p->unlocked_ns / NS_PER_S;
    out->unlocks_since_servo = out->servo_on ? p->unlock_count - p->count_at_servo : 0;
    out->unlocked_since_servo_s =
        out->servo_on ? (double)(p->unlocked_ns - p->unlocked_ns_at_servo) / NS_PER_S : 0.0;
    out->longest_since_servo_s = (double)p->longest_since_servo_ns / NS_PER_S;
    out->drop_open = p->drop_open != 0;
    out->last_unlock_age_s = age_s(now, p->last_unlock_start_ns);
    if (p->drop_open)
        out->last_unlock_s = (double)(now - p->last_unlock_start_ns) / NS_PER_S;
    else if (p->last_unlock_start_ns)
        out->last_unlock_s = (double)p->last_unlock_ns / NS_PER_S;
    else
        out->last_unlock_s = -1.0;
    out->raw_unlock_edges = p->raw_unlock_edges;
    return RP_OK;
}

int mon_GetUnlockEvents(rp_pid_t pid, uint32_t after, rp_unlock_event_t *out, uint32_t *n)
{
    struct lockbox_monitor m;
    uint64_t now;
    if (pid > RP_PID_22)
        return RP_EPN;
    int result = mon_Snapshot(&m, &now);
    if (result != RP_OK)
        return result;
    const struct lockbox_monitor_pid *p = &m.pids[pid];

    uint64_t head = p->event_head;
    uint64_t avail = head < LOCKBOX_MONITOR_EVENTS ? head : LOCKBOX_MONITOR_EVENTS;
    *n = 0;
    for (uint64_t i = head - avail; i < head; i++) {
        const struct lockbox_monitor_event *ev = &p->events[i % LOCKBOX_MONITOR_EVENTS];
        if (ev->index <= after)
            continue;
        out[*n].index = (uint32_t)ev->index;
        out[*n].age_s = age_s(now, ev->start_ns);
        out[*n].duration_s = (double)ev->duration_ns / NS_PER_S;
        (*n)++;
    }
    return RP_OK;
}

int mon_GetHealth(bool *alive, double *uptime_s, double *period_ms, double *max_gap_ms,
                  uint64_t *late_polls, double *merge_ms)
{
    struct lockbox_monitor m;
    uint64_t now;
    int result = mon_Snapshot(&m, &now);
    if (result != RP_OK) {
        *alive = false;
        *uptime_s = -1.0;
        *period_ms = *max_gap_ms = *merge_ms = 0.0;
        *late_polls = 0;
        return result;
    }
    *alive = true;
    *uptime_s = age_s(now, m.start_ns);
    *period_ms = (double)m.poll_period_ns / 1e6;
    *max_gap_ms = (double)m.max_gap_ns / 1e6;
    *late_polls = m.late_polls;
    *merge_ms = (double)m.merge_ns / 1e6;
    return RP_OK;
}

int mon_GetInStats(rp_channel_t channel, double *mean, double *sd, double *min, double *max,
                   double *window_s, double *age_s_out, uint32_t *decimation)
{
    struct lockbox_monitor m;
    uint64_t now;
    if (channel > RP_CH_2)
        return RP_EPN;
    int result = mon_Snapshot(&m, &now);
    if (result != RP_OK)
        return result;
    const struct lockbox_monitor_input *in = &m.inputs[channel];
    *mean = in->mean_v;
    *sd = in->sd_v;
    *min = in->min_v;
    *max = in->max_v;
    *window_s = in->window_s;
    *age_s_out = age_s(now, in->updated_ns);
    *decimation = in->decimation;
    return RP_OK;
}

bool mon_ValidStatsDecimation(uint32_t decimation)
{
    return decimation == 64 || decimation == 1024 || decimation == 8192 || decimation == 65536;
}

int mon_SetStatsDecimation(uint32_t decimation)
{
    struct lockbox_monitor m;
    uint64_t now;
    if (!mon_ValidStatsDecimation(decimation))
        return RP_EOOR;
    /* Only a running monitor takes requests */
    int result = mon_Snapshot(&m, &now);
    if (result != RP_OK)
        return result;
    int fd = shm_open(LOCKBOX_MONITOR_SHM, O_RDWR, 0);
    if (fd == -1)
        return RP_EMON;
    void *map = mmap(NULL, sizeof(struct lockbox_monitor), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (map == MAP_FAILED)
        return RP_EMON;
    __atomic_store_n(&((volatile struct lockbox_monitor *)map)->stats_decimation_request,
                     decimation, __ATOMIC_RELEASE);
    munmap(map, sizeof(struct lockbox_monitor));
    return RP_OK;
}

int mon_GetStatsDecimation(uint32_t *decimation)
{
    struct lockbox_monitor m;
    uint64_t now;
    int result = mon_Snapshot(&m, &now);
    if (result != RP_OK)
        return result;
    *decimation = m.stats_enabled ? m.inputs[0].decimation : 0;
    return RP_OK;
}
