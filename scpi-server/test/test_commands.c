/**
 * Copyright (c) 2026, Lothar Maisenbacher
 *
 * All rights reserved.
 *
 * Host test of the SCPI command table (src/scpi-commands.c): every spelling of
 * the PID commands, old and new, resolves to the right handler, with the tag
 * that selects the parameter set and the input and output numbers. The
 * lookup is libscpi's: the first pattern in the table that matchCommand
 * accepts. commands.inc is the table, extracted by the Makefile.
 */

#include <stdio.h>
#include <string.h>

#include "scpi/types.h"
#include "utils_private.h"

typedef struct {
    const char *pattern;
    const char *callback;
    int tag;
} entry_t;

static const entry_t table[] = {
#include "commands.inc"
    {NULL, NULL, 0}
};

static int failures = 0;
static int checks = 0;

// Resolve a header like the parser: the first matching pattern
static const entry_t *lookup(const char *header, int32_t numbers[2])
{
    for (int i = 0; table[i].pattern != NULL; i++) {
        if (matchCommand(table[i].pattern, header, strlen(header), NULL, 0, 0)) {
            numbers[0] = numbers[1] = -1;
            matchCommand(table[i].pattern, header, strlen(header), numbers, 2, 1);
            return &table[i];
        }
    }
    return NULL;
}

static void expect(const char *header, const char *callback, int tag, int in, int out)
{
    int32_t numbers[2];
    const entry_t *e = lookup(header, numbers);

    checks++;
    if (callback == NULL) {
        if (e != NULL) {
            failures++;
            printf("  FAIL: %s matched %s, expected no match\n", header, e->callback);
        }
        return;
    }
    if (e == NULL) {
        failures++;
        printf("  FAIL: %s matched nothing, expected %s\n", header, callback);
    }
    else if (strcmp(e->callback, callback) != 0 || e->tag != tag
             || (in > 0 && (numbers[0] != in || numbers[1] != out))) {
        failures++;
        printf("  FAIL: %s -> %s tag %d IN%d OUT%d, expected %s tag %d IN%d OUT%d\n",
               header, e->callback, e->tag, numbers[0], numbers[1], callback, tag, in, out);
    }
}

int main(void)
{
    printf("test_commands\n");

    // The parameters of parameter set 1, as clients always wrote them
    expect("PID:IN1:OUT1:SETPoint", "RP_PIDSetpoint", 0, 1, 1);
    expect("PID:IN1:OUT1:SETP?", "RP_PIDSetpointQ", 0, 1, 1);
    expect("PID:IN2:OUT1:KG", "RP_PIDKg", 0, 2, 1);
    expect("PID:IN1:OUT2:KP", "RP_PIDKp", 0, 1, 2);
    expect("PID:IN2:OUT2:KP?", "RP_PIDKpQ", 0, 2, 2);
    expect("PID:IN1:OUT1:KI", "RP_PIDKi", 0, 1, 1);
    expect("PID:IN1:OUT1:KII?", "RP_PIDKiiQ", 0, 1, 1);
    expect("PID:IN1:OUT1:KD", "RP_PIDKd", 0, 1, 1);
    expect("PID:IN1:OUT1:RELock:MIN", "RP_PIDRelockMin", 0, 1, 1);
    expect("PID:IN1:OUT1:REL:MAX?", "RP_PIDRelockMaxQ", 0, 1, 1);
    expect("pid:in2:out1:kp?", "RP_PIDKpQ", 0, 2, 1);
    expect("PID:IN:OUT:KP", "RP_PIDKp", 0, 1, 1);
    // ... and with the node
    expect("PID:IN1:OUT1:PSET1:KP", "RP_PIDKp", 0, 1, 1);
    expect("PID:IN2:OUT2:PSET1:REL:MIN?", "RP_PIDRelockMinQ", 0, 2, 2);
    expect("PID:IN1:OUT1:PSET1:RELock:HOLDoff", "RP_PIDHoldoff", 0, 1, 1);
    expect("PID:IN1:OUT1:REL:HOLD?", "RP_PIDHoldoffQ", 0, 1, 1);

    // Parameter set 2
    expect("PID:IN1:OUT1:PSET2:SETPoint", "RP_PIDSetpoint", 1, 1, 1);
    expect("PID:IN2:OUT1:PSET2:SETP?", "RP_PIDSetpointQ", 1, 2, 1);
    expect("PID:IN1:OUT2:PSET2:KG", "RP_PIDKg", 1, 1, 2);
    expect("PID:IN1:OUT1:PSET2:KP?", "RP_PIDKpQ", 1, 1, 1);
    expect("PID:IN1:OUT1:PSET2:KI", "RP_PIDKi", 1, 1, 1);
    expect("pid:in2:out2:pset2:kii?", "RP_PIDKiiQ", 1, 2, 2);
    expect("PID:IN1:OUT1:PSET2:KD", "RP_PIDKd", 1, 1, 1);
    expect("PID:IN1:OUT1:PSET2:REL:MIN", "RP_PIDRelockMin", 1, 1, 1);
    expect("PID:IN1:OUT1:PSET2:RELock:MAX?", "RP_PIDRelockMaxQ", 1, 1, 1);
    expect("PID:IN1:OUT1:PSET2:REL:HOLDoff", "RP_PIDHoldoff", 1, 1, 1);
    expect("PID:IN1:OUT1:PSET2:REL:HOLD?", "RP_PIDHoldoffQ", 1, 1, 1);

    // The selection
    expect("PID:IN1:OUT1:PSET:MODE", "RP_PIDPSetMode", 0, 1, 1);
    expect("PID:IN2:OUT2:PSET:MODE?", "RP_PIDPSetModeQ", 0, 2, 2);
    expect("PID:IN1:OUT2:PSET:INPut", "RP_PIDPSetInput", 0, 1, 2);
    expect("PID:IN1:OUT1:PSET:INP?", "RP_PIDPSetInputQ", 0, 1, 1);
    expect("PID:IN1:OUT1:PSET:ACTive?", "RP_PIDPSetActiveQ", 0, 1, 1);
    expect("PID:IN1:OUT1:PSET:COPY", "RP_PIDPSetCopy", 0, 1, 1);

    // The commands around them are unchanged
    expect("PID:IN1:OUT1:HOLD", "RP_PIDHold", 0, 1, 1);
    expect("PID:IN1:OUT1:HOLD?", "RP_PIDHoldQ", 0, 1, 1);
    expect("PID:IN1:OUT1:RELock", "RP_PIDRelock", 0, 1, 1);
    expect("PID:IN1:OUT1:REL?", "RP_PIDRelockQ", 0, 1, 1);
    expect("PID:IN1:OUT1:REL:STEP", "RP_PIDRelockStepsize", 0, 1, 1);
    expect("PID:IN1:OUT1:REL:INP?", "RP_PIDRelockInputQ", 0, 1, 1);
    expect("PID:IN1:OUT1:LOCKED?", "RP_PIDLockedQ", 0, 1, 1);
    expect("PID:IN1:OUT1:ENAB", "RP_PIDEnable", 0, 1, 1);

    // Switching between lock and scan, apart from the lock status
    expect("PID:IN2:OUT1:LOCK", "RP_PIDLock", 0, 2, 1);
    expect("PID:IN1:OUT2:LOCK?", "RP_PIDLockQ", 0, 1, 2);
    expect("PID:IN1:OUT1:LOCKED", NULL, 0, 0, 0);
    expect("PID:IN1:OUT1:PSET2:LOCK", NULL, 0, 0, 0);
    expect("PID:IN1:OUT1:INT:RES?", "RP_PIDIntResetQ", 0, 1, 1);
    expect("PID:IN1:OUT1:INV", "RP_PIDInverted", 0, 1, 1);
    expect("PID:IN1:OUT1:MON?", "RP_PIDMonitorQ", 0, 1, 1);
    expect("PID:IN2:OUT1:COUNTers?", "RP_PIDCountersQ", 0, 2, 1);
    expect("PID:IN1:OUT2:COUNT?", "RP_PIDCountersQ", 0, 1, 2);
    expect("PID:IN2:OUT2:UNL:SHOR?", "RP_PIDUnlockShortQ", 0, 2, 2);
    expect("PID:IN1:OUT1:UNL:COUN?", "RP_PIDUnlockCountQ", 0, 1, 1);
    expect("LOCK:CONF:SAVE", "RP_SaveLockboxConfig", 0, 0, 0);
    expect("LOCKbox:MONitor?", "RP_LockboxMonitorQ", 0, 0, 0);
    expect("OUT1:LIM:MIN", "RP_OutputLimitMin", 0, 0, 0);

    // Not commands: what stays shared has no set node, there is no third set,
    // and the set nodes are whole keywords
    expect("PID:IN1:OUT1:PSET2:REL:STEP", NULL, 0, 0, 0);
    expect("PID:IN1:OUT1:PSET2:REL:INP", NULL, 0, 0, 0);
    expect("PID:IN1:OUT1:PSET2:HOLD", NULL, 0, 0, 0);
    expect("PID:IN1:OUT1:PSET1:HOLD", NULL, 0, 0, 0);
    expect("PID:IN1:OUT1:PSET3:KP", NULL, 0, 0, 0);
    expect("PID:IN1:OUT1:PSET:KP", NULL, 0, 0, 0);
    expect("PID:IN1:OUT1:PSET2", NULL, 0, 0, 0);

    if (failures == 0)
        printf("PASS (%d checks)\n", checks);
    else
        printf("FAIL (%d of %d checks failed)\n", failures, checks);
    return failures != 0;
}
