/**
 * Copyright (c) 2026, Lothar Maisenbacher
 *
 * All rights reserved.
 *
 * @brief The lock monitor's shared-memory block.
 *
 * The lock monitor daemon (lockbox-monitor) samples the FPGA's lock and
 * hold flags every millisecond, counts lock drops, and measures the fast
 * inputs' noise with the scope block. It publishes its state in a POSIX
 * shared-memory block (/dev/shm/lockbox-monitor); liblockbox reads the
 * block for the SCPI server and the web interface (rp_PIDGetMonitor and
 * friends in lockbox.h). Daemon and library compile against this one
 * layout, guarded by LOCKBOX_MONITOR_LAYOUT.
 *
 * All times are CLOCK_MONOTONIC nanoseconds; readers report ages and
 * durations, never wall-clock stamps. The block is a seqlock: the writer
 * increments `seq` to an odd value, writes, then increments it again;
 * a reader copies the block and retries when `seq` was odd or changed.
 * The one exception is `stats_decimation_request`, written by consumers
 * and read by the daemon, which lies outside the seqlock's protection.
 */

#ifndef __LOCKBOX_MONITOR_H
#define __LOCKBOX_MONITOR_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Name of the shared-memory block (shm_open) */
#define LOCKBOX_MONITOR_SHM "/lockbox-monitor"
/** Layout version; readers refuse a block of another layout */
#define LOCKBOX_MONITOR_LAYOUT 1
/** The four PID controllers, indexed like rp_pid_t */
#define LOCKBOX_MONITOR_PIDS 4
/** The two fast analog inputs, indexed like rp_channel_t */
#define LOCKBOX_MONITOR_INPUTS 2
/** Lock-drop events kept per PID */
#define LOCKBOX_MONITOR_EVENTS 64
/** A block whose last poll is older than this counts as dead */
#define LOCKBOX_MONITOR_STALE_NS 2000000000ULL

/** One lock drop */
struct lockbox_monitor_event {
    uint64_t index;         /**< 1-based, increasing per PID */
    uint64_t start_ns;      /**< the poll that saw the flag fall */
    uint64_t duration_ns;   /**< to the first poll of the lock stretch that closed it */
};

/** One PID controller's lock monitoring */
struct lockbox_monitor_pid {
    uint32_t locked;                /**< merged lock state at the last poll */
    uint32_t held;                  /**< hold flag at the last poll */
    uint32_t raw_locked;            /**< the FPGA flag as read at the last poll */
    uint32_t drop_open;             /**< a lock drop is in progress */
    uint64_t state_since_ns;        /**< start of the current locked/unlocked stretch */
    uint64_t servo_since_ns;        /**< the last hold on->off edge; 0 = hold on */
    uint64_t unlock_count;          /**< lock drops since the monitor started */
    uint64_t unlocked_ns;           /**< time spent in lock drops, the open one included */
    uint64_t raw_unlock_edges;      /**< falling edges of the flag, before merging */
    uint64_t count_at_servo;        /**< unlock_count at the last hold on->off edge */
    uint64_t unlocked_ns_at_servo;  /**< unlocked_ns at the last hold on->off edge */
    uint64_t longest_since_servo_ns;/**< longest drop since the last hold on->off edge */
    uint64_t last_unlock_start_ns;  /**< start of the latest drop; 0 = none yet */
    uint64_t last_unlock_ns;        /**< duration of the latest closed drop; 0 = none yet */
    uint64_t event_head;            /**< events pushed so far (= the next index) */
    uint64_t streak_since_ns;       /**< internal: first locked poll inside an open drop */
    uint64_t drop_base_ns;          /**< internal: unlocked_ns when the open drop began */
    uint64_t reserved;
    struct lockbox_monitor_event events[LOCKBOX_MONITOR_EVENTS]; /**< ring, index % EVENTS */
};

/** One fast analog input's noise statistics over the last window */
struct lockbox_monitor_input {
    double mean_v;
    double sd_v;                /**< standard deviation about the window mean */
    double min_v;
    double max_v;
    double window_s;            /**< length of the window the statistics cover */
    uint64_t updated_ns;        /**< end of that window; 0 = no window yet */
    uint64_t n_samples;
    uint32_t decimation;        /**< scope decimation the samples were averaged over */
    uint32_t reserved;
};

/** The shared block */
struct lockbox_monitor {
    uint32_t seq;               /**< seqlock counter, odd while the writer updates */
    uint32_t layout;            /**< LOCKBOX_MONITOR_LAYOUT */
    uint32_t pid;               /**< the daemon's process id; 0 after a clean exit */
    uint32_t stats_enabled;     /**< the input statistics thread runs */
    uint64_t start_ns;          /**< the daemon's first poll */
    uint64_t last_poll_ns;
    uint64_t poll_period_ns;
    uint64_t polls;
    uint64_t late_polls;        /**< polls more than two periods after the previous one */
    uint64_t max_gap_ns;        /**< longest interval between two polls */
    uint64_t merge_ns;          /**< lock time that closes a drop */
    uint64_t grace_ns;          /**< startup time during which nothing is counted */
    struct lockbox_monitor_pid pids[LOCKBOX_MONITOR_PIDS];
    struct lockbox_monitor_input inputs[LOCKBOX_MONITOR_INPUTS];
    /* Written by consumers (rp_MonitorSetStatsDecimation), consumed by the
     * daemon between windows; 0 = no request pending. Not seqlock-protected. */
    uint32_t stats_decimation_request;
    uint32_t reserved;
};

/* The layout must be identical on the Red Pitaya (ARM) and the hosts
 * that run the daemon's tests; every 64-bit field sits at an 8-byte
 * offset by construction, so the sizes are the same on both. */
#define LOCKBOX_MONITOR_EVENT_SIZE 24
#define LOCKBOX_MONITOR_PID_SIZE (4*4 + 14*8 + LOCKBOX_MONITOR_EVENTS*LOCKBOX_MONITOR_EVENT_SIZE)
#define LOCKBOX_MONITOR_INPUT_SIZE (5*8 + 2*8 + 2*4)
#define LOCKBOX_MONITOR_SIZE (4*4 + 8*8 + LOCKBOX_MONITOR_PIDS*LOCKBOX_MONITOR_PID_SIZE \
                              + LOCKBOX_MONITOR_INPUTS*LOCKBOX_MONITOR_INPUT_SIZE + 2*4)

#ifdef __cplusplus
}
#endif

#endif /* __LOCKBOX_MONITOR_H */
