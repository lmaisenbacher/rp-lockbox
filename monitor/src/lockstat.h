/**
 * Copyright (c) 2026, Lothar Maisenbacher
 *
 * All rights reserved.
 *
 * @brief Lock-drop bookkeeping for one PID controller: the pure state
 * machine behind the lockbox monitor, without any I/O.
 *
 * Every poll feeds the FPGA's lock flag and the PID's hold flag with the
 * poll time. The rules (see the README's "Lockbox monitor"):
 *
 * - MODE is the hold flag: hold off = "servo on". A hold on->off edge
 *   (the web interface's Lock press) records the servo-on time and resets the
 *   "since servo on" counters.
 * - A DROP is a locked->unlocked edge of the flag while the servo is on.
 *   It stays open until the flag has read locked for `merge_ns` in a row,
 *   so the flicker while the relock sweep re-finds the resonance is one
 *   drop; the drop's duration runs to the first poll of that closing lock
 *   stretch. Falling edges inside an open drop count as raw edges only.
 * - The acquisition after a Lock press is an unlocked->locked edge and is
 *   never a drop; edges while the hold is on are tracked but not counted.
 * - Nothing is counted during the startup grace (the SCPI server
 *   re-programs the lock window right after the bitstream load).
 * - With an FPGA image that counts every loss of lock, the poll also
 *   learns whether the lock was lost since the previous poll. If it was,
 *   and both polls read locked, the lock was lost and found again between
 *   them: a SHORT DROP, which began at the previous poll and has been
 *   locked since this one, so it merges with what follows within
 *   `merge_ns` like any drop and closes with a duration of one poll
 *   interval. Inside an open drop, such a loss restarts the lock stretch
 *   that closes it.
 */

#ifndef __LOCKSTAT_H
#define __LOCKSTAT_H

#include <stdint.h>
#include "redpitaya/lockbox_monitor.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Start the bookkeeping of one PID from its state at the first poll:
 * nothing is an edge yet. A servo already on counts as on since now.
 */
void lockstat_init(struct lockbox_monitor_pid *p, uint64_t now_ns, int locked, int held);

/**
 * One poll at `now_ns`, the previous one at `prev_ns`. `lost` is 1 if the
 * FPGA's unlock counter rose since the previous poll (0 without one).
 * `counting` is 0 during the startup grace (state is tracked, no drop
 * opens); `merge_ns` is the lock time that closes a drop.
 */
void lockstat_poll(struct lockbox_monitor_pid *p, uint64_t prev_ns, uint64_t now_ns,
                   int locked, int held, int lost, uint64_t merge_ns, int counting);

#ifdef __cplusplus
}
#endif

#endif /* __LOCKSTAT_H */
