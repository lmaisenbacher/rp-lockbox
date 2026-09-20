/**
 * Copyright (c) 2026, Lothar Maisenbacher
 *
 * All rights reserved.
 *
 * @brief Reader of the lockbox monitor's shared-memory block (lockbox_monitor.h)
 * for the rp_PIDGetMonitor family of API functions.
 */

#ifndef __MONITOR_H
#define __MONITOR_H

#include <stdint.h>
#include <stdbool.h>
#include "redpitaya/lockbox.h"
#include "redpitaya/lockbox_monitor.h"

/* Copy a consistent snapshot of the block and the monotonic time it was
 * taken at; RP_EMON while the monitor is not running */
int mon_Snapshot(struct lockbox_monitor *out, uint64_t *now_ns);

/* Drop the mapping (a later call maps the block again) */
void mon_Release();

int mon_GetPID(rp_pid_t pid, rp_pid_monitor_t *out);
int mon_GetUnlockEvents(rp_pid_t pid, uint32_t after, rp_unlock_event_t *out, uint32_t *n);
int mon_GetHealth(bool *alive, double *uptime_s, double *period_ms, double *max_gap_ms,
                  uint64_t *late_polls, double *merge_ms);
int mon_GetInStats(rp_channel_t channel, double *mean, double *sd, double *min, double *max,
                   double *window_s, double *age_s, uint32_t *decimation);
int mon_SetStatsDecimation(uint32_t decimation);
int mon_GetStatsDecimation(uint32_t *decimation);

/* The decimations the monitor's statistics thread accepts */
bool mon_ValidStatsDecimation(uint32_t decimation);

#endif /* __MONITOR_H */
