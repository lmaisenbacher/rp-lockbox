/**
 * Copyright (c) 2026, Lothar Maisenbacher
 *
 * All rights reserved.
 *
 * @brief Prints the lockbox monitor's shared block through liblockbox's reader
 * (api/src/monitor.c), one "key=value" per line - the test harness greps
 * it, and it is a handy inspection tool on the Red Pitaya as well.
 *
 *   readmon                   health, the four PIDs, the two inputs
 *   readmon --events <pid>    the event ring of PID 0-3
 *   readmon --set-decimation <n>
 *
 * Exit status 0 while the monitor is running, 1 when it is not.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "monitor.h"

static void print_pid(int pid)
{
    rp_pid_monitor_t m;
    if (mon_GetPID((rp_pid_t)pid, &m) != RP_OK) {
        printf("pid%d.error=1\n", pid);
        return;
    }
    printf("pid%d.locked=%d\n", pid, m.locked);
    printf("pid%d.lock_age_s=%.3f\n", pid, m.lock_age_s);
    printf("pid%d.servo_on=%d\n", pid, m.servo_on);
    printf("pid%d.servo_age_s=%.3f\n", pid, m.servo_age_s);
    printf("pid%d.unlocks_total=%llu\n", pid, (unsigned long long)m.unlocks_total);
    printf("pid%d.unlocked_total_s=%.4f\n", pid, m.unlocked_total_s);
    printf("pid%d.unlocks_since_servo=%llu\n", pid, (unsigned long long)m.unlocks_since_servo);
    printf("pid%d.unlocked_since_servo_s=%.4f\n", pid, m.unlocked_since_servo_s);
    printf("pid%d.longest_since_servo_s=%.4f\n", pid, m.longest_since_servo_s);
    printf("pid%d.drop_open=%d\n", pid, m.drop_open);
    printf("pid%d.last_unlock_age_s=%.3f\n", pid, m.last_unlock_age_s);
    printf("pid%d.last_unlock_s=%.4f\n", pid, m.last_unlock_s);
    printf("pid%d.raw_unlock_edges=%llu\n", pid, (unsigned long long)m.raw_unlock_edges);
}

static void print_input(int ch)
{
    double mean, sd, min, max, window, age;
    uint32_t dec;
    if (mon_GetInStats((rp_channel_t)ch, &mean, &sd, &min, &max, &window, &age, &dec) != RP_OK) {
        printf("in%d.error=1\n", ch + 1);
        return;
    }
    printf("in%d.mean_v=%.6f\n", ch + 1, mean);
    printf("in%d.sd_v=%.6f\n", ch + 1, sd);
    printf("in%d.min_v=%.6f\n", ch + 1, min);
    printf("in%d.max_v=%.6f\n", ch + 1, max);
    printf("in%d.window_s=%.3f\n", ch + 1, window);
    printf("in%d.age_s=%.3f\n", ch + 1, age);
    printf("in%d.decimation=%u\n", ch + 1, dec);
}

int main(int argc, char *argv[])
{
    if (argc == 3 && strcmp(argv[1], "--set-decimation") == 0) {
        int result = mon_SetStatsDecimation((uint32_t)strtoul(argv[2], NULL, 10));
        printf("set_decimation.result=%d\n", result);
        return result == RP_OK ? EXIT_SUCCESS : EXIT_FAILURE;
    }
    if (argc == 3 && strcmp(argv[1], "--events") == 0) {
        rp_unlock_event_t events[LOCKBOX_MONITOR_EVENTS];
        uint32_t n;
        int result = mon_GetUnlockEvents((rp_pid_t)atoi(argv[2]), 0, events, &n);
        if (result != RP_OK) {
            printf("events.error=%d\n", result);
            return EXIT_FAILURE;
        }
        printf("events.n=%u\n", n);
        for (uint32_t i = 0; i < n; i++)
            printf("event.%u=%.3f,%.4f\n", events[i].index, events[i].age_s, events[i].duration_s);
        return EXIT_SUCCESS;
    }

    bool alive;
    double uptime, period, max_gap, merge;
    uint64_t late;
    int result = mon_GetHealth(&alive, &uptime, &period, &max_gap, &late, &merge);
    printf("monitor.alive=%d\n", alive);
    if (result != RP_OK)
        return EXIT_FAILURE;
    printf("monitor.uptime_s=%.3f\n", uptime);
    printf("monitor.period_ms=%.3f\n", period);
    printf("monitor.max_gap_ms=%.3f\n", max_gap);
    printf("monitor.late_polls=%llu\n", (unsigned long long)late);
    printf("monitor.merge_ms=%.3f\n", merge);
    uint32_t dec = 0;
    mon_GetStatsDecimation(&dec);
    printf("monitor.stats_decimation=%u\n", dec);
    for (int pid = 0; pid < LOCKBOX_MONITOR_PIDS; pid++)
        print_pid(pid);
    for (int ch = 0; ch < LOCKBOX_MONITOR_INPUTS; ch++)
        print_input(ch);
    return EXIT_SUCCESS;
}
