/**
 * Copyright (c) 2026, Lothar Maisenbacher
 *
 * All rights reserved.
 *
 * @brief Tests of the lock-drop state machine (lockstat.c), run on any host:
 * polls are fed with synthetic millisecond times.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lockstat.h"

#define MS 1000000ULL
#define MERGE (10 * MS)

static int failures = 0;

#define CHECK(cond) do { \
    if (!(cond)) { \
        printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
        failures++; \
    } \
} while (0)

#define CHECK_EQ(a, b) do { \
    unsigned long long _a = (unsigned long long)(a), _b = (unsigned long long)(b); \
    if (_a != _b) { \
        printf("FAIL %s:%d: %s = %llu, expected %s = %llu\n", __FILE__, __LINE__, #a, _a, #b, _b); \
        failures++; \
    } \
} while (0)

/* `n` polls one millisecond apart, `*t` advanced past them */
static void polls(struct lockbox_monitor_pid *p, uint64_t *t, int n, int locked, int held, int counting)
{
    for (int i = 0; i < n; i++) {
        *t += MS;
        lockstat_poll(p, *t, locked, held, MERGE, counting);
    }
}

static void fresh(struct lockbox_monitor_pid *p, uint64_t *t, int locked, int held)
{
    *t = 1000 * MS;
    lockstat_init(p, *t, locked, held);
}

static void test_init()
{
    struct lockbox_monitor_pid p;
    uint64_t t;
    fresh(&p, &t, 1, 0);
    CHECK_EQ(p.locked, 1);
    CHECK_EQ(p.servo_since_ns, t);
    CHECK_EQ(p.state_since_ns, t);
    CHECK_EQ(p.unlock_count, 0);
    fresh(&p, &t, 0, 1);
    CHECK_EQ(p.locked, 0);
    CHECK_EQ(p.servo_since_ns, 0);
    /* The first polls in the initial state are no edges */
    polls(&p, &t, 5, 0, 1, 1);
    CHECK_EQ(p.unlock_count, 0);
    CHECK_EQ(p.raw_unlock_edges, 0);
}

static void test_simple_drop()
{
    struct lockbox_monitor_pid p;
    uint64_t t;
    fresh(&p, &t, 1, 0);
    polls(&p, &t, 100, 1, 0, 1);
    uint64_t t_fall = t + MS;
    polls(&p, &t, 3, 0, 0, 1);
    CHECK_EQ(p.drop_open, 1);
    CHECK_EQ(p.unlock_count, 1);
    CHECK_EQ(p.locked, 0);
    CHECK_EQ(p.state_since_ns, t_fall);
    CHECK_EQ(p.last_unlock_start_ns, t_fall);
    /* The live total while the drop lasts */
    CHECK_EQ(p.unlocked_ns, 2 * MS);
    uint64_t t_rise = t + MS;
    polls(&p, &t, 10, 1, 0, 1);
    /* Ten locked polls span 9 ms: not yet solid */
    CHECK_EQ(p.drop_open, 1);
    CHECK_EQ(p.locked, 0);
    CHECK_EQ(p.event_head, 0);
    polls(&p, &t, 1, 1, 0, 1);
    /* Locked for 10 ms: the drop closes, dated at the first locked poll */
    CHECK_EQ(p.drop_open, 0);
    CHECK_EQ(p.locked, 1);
    CHECK_EQ(p.state_since_ns, t_rise);
    CHECK_EQ(p.unlock_count, 1);
    CHECK_EQ(p.raw_unlock_edges, 1);
    CHECK_EQ(p.event_head, 1);
    CHECK_EQ(p.events[0].index, 1);
    CHECK_EQ(p.events[0].start_ns, t_fall);
    CHECK_EQ(p.events[0].duration_ns, t_rise - t_fall);
    CHECK_EQ(p.events[0].duration_ns, 3 * MS);
    CHECK_EQ(p.last_unlock_ns, 3 * MS);
    CHECK_EQ(p.unlocked_ns, 3 * MS);
    CHECK_EQ(p.longest_since_servo_ns, 3 * MS);
    CHECK_EQ(p.count_at_servo, 0);
    /* Nothing more happens while locked */
    polls(&p, &t, 500, 1, 0, 1);
    CHECK_EQ(p.unlock_count, 1);
    CHECK_EQ(p.unlocked_ns, 3 * MS);
}

static void test_flicker_merges()
{
    struct lockbox_monitor_pid p;
    uint64_t t;
    fresh(&p, &t, 1, 0);
    polls(&p, &t, 50, 1, 0, 1);
    uint64_t t_fall = t + MS;
    polls(&p, &t, 4, 0, 0, 1);
    polls(&p, &t, 2, 1, 0, 1);      /* back inside the merge time */
    polls(&p, &t, 4, 0, 0, 1);
    uint64_t t_rise = t + MS;
    polls(&p, &t, 30, 1, 0, 1);
    CHECK_EQ(p.unlock_count, 1);
    CHECK_EQ(p.raw_unlock_edges, 2);
    CHECK_EQ(p.event_head, 1);
    CHECK_EQ(p.events[0].duration_ns, t_rise - t_fall);
    CHECK_EQ(p.events[0].duration_ns, 10 * MS);
    CHECK_EQ(p.unlocked_ns, 10 * MS);
}

static void test_separate_drops()
{
    struct lockbox_monitor_pid p;
    uint64_t t;
    fresh(&p, &t, 1, 0);
    polls(&p, &t, 50, 1, 0, 1);
    polls(&p, &t, 4, 0, 0, 1);
    polls(&p, &t, 30, 1, 0, 1);     /* longer than the merge time */
    polls(&p, &t, 6, 0, 0, 1);
    polls(&p, &t, 30, 1, 0, 1);
    CHECK_EQ(p.unlock_count, 2);
    CHECK_EQ(p.raw_unlock_edges, 2);
    CHECK_EQ(p.event_head, 2);
    CHECK_EQ(p.events[0].duration_ns, 4 * MS);
    CHECK_EQ(p.events[1].duration_ns, 6 * MS);
    CHECK_EQ(p.events[1].index, 2);
    CHECK_EQ(p.last_unlock_ns, 6 * MS);
    CHECK_EQ(p.longest_since_servo_ns, 6 * MS);
    CHECK_EQ(p.unlocked_ns, 10 * MS);
}

static void test_held_counts_nothing()
{
    struct lockbox_monitor_pid p;
    uint64_t t;
    fresh(&p, &t, 1, 1);
    polls(&p, &t, 20, 1, 1, 1);
    uint64_t t_fall = t + MS;
    polls(&p, &t, 20, 0, 1, 1);
    CHECK_EQ(p.locked, 0);
    CHECK_EQ(p.state_since_ns, t_fall);
    polls(&p, &t, 20, 1, 1, 1);
    polls(&p, &t, 20, 0, 1, 1);
    CHECK_EQ(p.unlock_count, 0);
    CHECK_EQ(p.raw_unlock_edges, 0);
    CHECK_EQ(p.unlocked_ns, 0);
    CHECK_EQ(p.servo_since_ns, 0);
}

static void test_lock_press_and_acquisition()
{
    struct lockbox_monitor_pid p;
    uint64_t t;
    fresh(&p, &t, 1, 0);
    polls(&p, &t, 50, 1, 0, 1);
    polls(&p, &t, 3, 0, 0, 1);
    polls(&p, &t, 30, 1, 0, 1);     /* one drop while servoing */
    CHECK_EQ(p.unlock_count, 1);
    /* Toggle to Scan: the flag flickers */
    polls(&p, &t, 10, 1, 1, 1);
    CHECK_EQ(p.servo_since_ns, 0);
    polls(&p, &t, 10, 0, 1, 1);
    polls(&p, &t, 10, 1, 1, 1);
    polls(&p, &t, 10, 0, 1, 1);
    CHECK_EQ(p.unlock_count, 1);
    /* The Lock press, with the flag unlocked */
    uint64_t t_press = t + MS;
    polls(&p, &t, 5, 0, 0, 1);
    CHECK_EQ(p.servo_since_ns, t_press);
    CHECK_EQ(p.count_at_servo, 1);
    CHECK_EQ(p.unlocked_ns_at_servo, 3 * MS);
    CHECK_EQ(p.longest_since_servo_ns, 0);
    /* The acquisition is not a drop */
    polls(&p, &t, 50, 1, 0, 1);
    CHECK_EQ(p.unlock_count, 1);
    CHECK_EQ(p.locked, 1);
    /* A drop after it counts against the new servo */
    polls(&p, &t, 7, 0, 0, 1);
    polls(&p, &t, 30, 1, 0, 1);
    CHECK_EQ(p.unlock_count, 2);
    CHECK_EQ(p.unlock_count - p.count_at_servo, 1);
    CHECK_EQ(p.longest_since_servo_ns, 7 * MS);
    CHECK_EQ(p.unlocked_ns - p.unlocked_ns_at_servo, 7 * MS);
}

static void test_hold_closes_open_drop()
{
    struct lockbox_monitor_pid p;
    uint64_t t;
    fresh(&p, &t, 1, 0);
    polls(&p, &t, 50, 1, 0, 1);
    polls(&p, &t, 5, 0, 0, 1);
    CHECK_EQ(p.drop_open, 1);
    uint64_t t_hold = t + MS;
    polls(&p, &t, 1, 0, 1, 1);
    CHECK_EQ(p.drop_open, 0);
    CHECK_EQ(p.event_head, 1);
    CHECK_EQ(p.events[0].duration_ns, t_hold - p.events[0].start_ns);
    CHECK_EQ(p.events[0].duration_ns, 5 * MS);
    CHECK_EQ(p.servo_since_ns, 0);
    /* Merged state follows the flag while scanning */
    CHECK_EQ(p.locked, 0);
    polls(&p, &t, 1, 1, 1, 1);
    CHECK_EQ(p.locked, 1);
}

static void test_grace()
{
    struct lockbox_monitor_pid p;
    uint64_t t;
    fresh(&p, &t, 1, 0);
    polls(&p, &t, 20, 1, 0, 0);
    uint64_t t_fall = t + MS;
    polls(&p, &t, 20, 0, 0, 0);     /* falls during the grace */
    CHECK_EQ(p.unlock_count, 0);
    CHECK_EQ(p.locked, 0);
    CHECK_EQ(p.state_since_ns, t_fall);
    polls(&p, &t, 20, 0, 0, 1);     /* the grace ends while unlocked */
    CHECK_EQ(p.unlock_count, 0);
    polls(&p, &t, 20, 1, 0, 1);     /* re-acquired: no drop */
    CHECK_EQ(p.unlock_count, 0);
    CHECK_EQ(p.locked, 1);
    polls(&p, &t, 2, 0, 0, 1);      /* the first real drop */
    polls(&p, &t, 20, 1, 0, 1);
    CHECK_EQ(p.unlock_count, 1);
}

static void test_ring_wraps()
{
    struct lockbox_monitor_pid p;
    uint64_t t;
    fresh(&p, &t, 1, 0);
    for (int i = 0; i < 70; i++) {
        polls(&p, &t, i + 1, 0, 0, 1);
        polls(&p, &t, 30, 1, 0, 1);
    }
    CHECK_EQ(p.unlock_count, 70);
    CHECK_EQ(p.event_head, 70);
    CHECK_EQ(p.events[69 % LOCKBOX_MONITOR_EVENTS].index, 70);
    CHECK_EQ(p.events[69 % LOCKBOX_MONITOR_EVENTS].duration_ns, 70 * MS);
    /* The oldest kept drop is number 7 */
    CHECK_EQ(p.events[(70 - LOCKBOX_MONITOR_EVENTS) % LOCKBOX_MONITOR_EVENTS].index, 7);
    CHECK_EQ(p.longest_since_servo_ns, 70 * MS);
    /* 1 + 2 + ... + 70 ms */
    CHECK_EQ(p.unlocked_ns, (70 * 71 / 2) * MS);
}

int main()
{
    test_init();
    test_simple_drop();
    test_flicker_merges();
    test_separate_drops();
    test_held_counts_nothing();
    test_lock_press_and_acquisition();
    test_hold_closes_open_drop();
    test_grace();
    test_ring_wraps();
    if (failures) {
        printf("%d check(s) failed\n", failures);
        return EXIT_FAILURE;
    }
    printf("test_lockstat: all checks passed\n");
    return EXIT_SUCCESS;
}
