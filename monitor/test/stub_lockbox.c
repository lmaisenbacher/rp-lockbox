/**
 * Copyright (c) 2026, Lothar Maisenbacher
 *
 * All rights reserved.
 *
 * @brief A stand-in for liblockbox on a development host: lets the lock
 * monitor daemon run end to end without a Red Pitaya.
 *
 * The lock and hold flags come from the environment variable STUB_SCRIPT,
 * a comma-separated list of segments "<polls>:<locked hex>:<held hex>"
 * (one hex digit each, bit i = PID i), replayed one entry per poll; the
 * last segment repeats forever. The scope returns a synthetic signal: 0.5 V
 * plus noise of 1 mV standard deviation on input 1, 0.25 V plus 2 mV on
 * input 2.
 */

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "redpitaya/lockbox.h"

struct segment {
    unsigned long polls;
    unsigned locked, held;
};

static struct segment script[256];
static int n_segments = 0;
static int current = 0;
static unsigned long done_in_segment = 0;
static int loaded = 0;

static void load_script()
{
    loaded = 1;
    const char *s = getenv("STUB_SCRIPT");
    if (!s || !*s) {
        script[0].polls = 1;
        script[0].locked = 0xF;
        script[0].held = 0;
        n_segments = 1;
        return;
    }
    char *copy = strdup(s);
    for (char *tok = strtok(copy, ","); tok && n_segments < 256; tok = strtok(NULL, ",")) {
        unsigned long polls;
        unsigned locked, held;
        if (sscanf(tok, "%lu:%x:%x", &polls, &locked, &held) == 3 && polls > 0) {
            script[n_segments].polls = polls;
            script[n_segments].locked = locked & 0xF;
            script[n_segments].held = held & 0xF;
            n_segments++;
        } else {
            fprintf(stderr, "stub: bad STUB_SCRIPT segment '%s'\n", tok);
            exit(2);
        }
    }
    free(copy);
    if (n_segments == 0) {
        fprintf(stderr, "stub: empty STUB_SCRIPT\n");
        exit(2);
    }
}

int rp_Attach() { return RP_OK; }
int rp_Init() { return RP_OK; }
int rp_Release() { return RP_OK; }
const char *rp_GetError(int errorCode) { (void)errorCode; return "stub error"; }

int rp_PIDGetLockHoldBits(uint8_t *locked, uint8_t *held)
{
    if (!loaded)
        load_script();
    *locked = (uint8_t)script[current].locked;
    *held = (uint8_t)script[current].held;
    done_in_segment++;
    if (done_in_segment >= script[current].polls && current + 1 < n_segments) {
        current++;
        done_in_segment = 0;
    }
    return RP_OK;
}

int rp_AcqSetTriggerSrc(rp_acq_trig_src_t source) { (void)source; return RP_OK; }
int rp_AcqSetAveraging(bool enabled) { (void)enabled; return RP_OK; }
int rp_AcqSetDecimation(rp_acq_decimation_t decimation) { (void)decimation; return RP_OK; }
int rp_AcqStart() { return RP_OK; }
int rp_AcqStop() { return RP_OK; }

/* Gaussian noise from two uniforms (Box-Muller) */
static double gaussian()
{
    double u1 = (rand() + 1.0) / (RAND_MAX + 2.0);
    double u2 = (rand() + 1.0) / (RAND_MAX + 2.0);
    return sqrt(-2.0 * log(u1)) * cos(2.0 * M_PI * u2);
}

int rp_AcqGetOldestDataV(rp_channel_t channel, uint32_t *size, float *buffer)
{
    double mean = channel == RP_CH_1 ? 0.5 : 0.25;
    double sd = channel == RP_CH_1 ? 0.001 : 0.002;
    if (*size > ADC_BUFFER_SIZE)
        *size = ADC_BUFFER_SIZE;
    for (uint32_t i = 0; i < *size; i++)
        buffer[i] = (float)(mean + sd * gaussian());
    return RP_OK;
}
