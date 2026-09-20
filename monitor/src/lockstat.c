/**
 * Copyright (c) 2026, Lothar Maisenbacher
 *
 * All rights reserved.
 *
 * @brief Lock-drop bookkeeping for one PID controller (see lockstat.h).
 */

#include <string.h>
#include "lockstat.h"

_Static_assert(sizeof(struct lockbox_monitor_event) == LOCKBOX_MONITOR_EVENT_SIZE,
               "lockbox_monitor_event layout");
_Static_assert(sizeof(struct lockbox_monitor_pid) == LOCKBOX_MONITOR_PID_SIZE,
               "lockbox_monitor_pid layout");

void lockstat_init(struct lockbox_monitor_pid *p, uint64_t now_ns, int locked, int held)
{
    memset(p, 0, sizeof(*p));
    p->locked = locked ? 1 : 0;
    p->raw_locked = p->locked;
    p->held = held ? 1 : 0;
    p->state_since_ns = now_ns;
    p->servo_since_ns = held ? 0 : now_ns;
}

/* Close the open drop: it lasted from its start to `end_ns`. */
static void close_drop(struct lockbox_monitor_pid *p, uint64_t end_ns)
{
    uint64_t duration = end_ns - p->last_unlock_start_ns;
    struct lockbox_monitor_event *ev = &p->events[p->event_head % LOCKBOX_MONITOR_EVENTS];

    p->drop_open = 0;
    p->streak_since_ns = 0;
    p->unlocked_ns = p->drop_base_ns + duration;
    p->last_unlock_ns = duration;
    if (duration > p->longest_since_servo_ns)
        p->longest_since_servo_ns = duration;
    ev->index = p->event_head + 1;
    ev->start_ns = p->last_unlock_start_ns;
    ev->duration_ns = duration;
    p->event_head++;
    p->locked = 1;
    p->state_since_ns = end_ns;
}

static void open_drop(struct lockbox_monitor_pid *p, uint64_t now_ns)
{
    p->drop_open = 1;
    p->streak_since_ns = 0;
    p->drop_base_ns = p->unlocked_ns;
    p->last_unlock_start_ns = now_ns;
    p->unlock_count++;
    p->raw_unlock_edges++;
    p->locked = 0;
    p->state_since_ns = now_ns;
}

void lockstat_poll(struct lockbox_monitor_pid *p, uint64_t now_ns, int locked, int held,
                   uint64_t merge_ns, int counting)
{
    int prev_raw = p->raw_locked ? 1 : 0;
    int prev_held = p->held ? 1 : 0;

    locked = locked ? 1 : 0;
    held = held ? 1 : 0;
    p->raw_locked = locked;
    p->held = held;

    /* Mode edges */
    if (held && !prev_held) {
        /* Lock -> Scan: a drop in progress ends here */
        if (p->drop_open)
            close_drop(p, now_ns);
        p->servo_since_ns = 0;
    } else if (!held && prev_held) {
        /* Scan -> Lock (the Lock press): the "since servo on" counters restart */
        p->servo_since_ns = now_ns;
        p->count_at_servo = p->unlock_count;
        p->unlocked_ns_at_servo = p->unlocked_ns;
        p->longest_since_servo_ns = 0;
    }

    if (held) {
        /* Scanning: the flag flickers as the scan crosses the resonance -
         * follow it, count nothing */
        if (locked != (int)p->locked) {
            p->locked = locked;
            p->state_since_ns = now_ns;
        }
        return;
    }

    if (!p->drop_open) {
        if (prev_raw && !locked) {
            if (counting) {
                open_drop(p, now_ns);
            } else {
                p->locked = 0;
                p->state_since_ns = now_ns;
            }
        } else if (!prev_raw && locked) {
            /* The acquisition (after a Lock press, or after a drop that
             * began during the grace or while scanning): not a drop */
            p->locked = 1;
            p->state_since_ns = now_ns;
        }
        return;
    }

    /* A drop is open */
    if (locked) {
        if (!prev_raw)
            p->streak_since_ns = now_ns;
        if (p->streak_since_ns && now_ns - p->streak_since_ns >= merge_ns) {
            close_drop(p, p->streak_since_ns);
            return;
        }
    } else {
        if (prev_raw)
            p->raw_unlock_edges++;
        p->streak_since_ns = 0;
    }
    /* Live total while the drop lasts (exact at close) */
    p->unlocked_ns = p->drop_base_ns + (now_ns - p->last_unlock_start_ns);
}
