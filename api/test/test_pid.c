/**
 * Copyright (c) 2026, Lothar Maisenbacher
 *
 * All rights reserved.
 *
 * Host tests of the PID register access (api/src/pid.c) against a register
 * block in memory: the register map of the FPGA (fpga/regset.rst), parameter
 * set 1 at the addresses the named functions always used, parameter set 2
 * at + 0x100, the conversions, and the refusal of the new functions on
 * an FPGA image without the parameter sets.
 */

#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#include "pid.h"
#include "calib.h"

static int failures = 0;
static int checks = 0;

#define CHECK(cond, msg) do { \
    checks++; \
    if (!(cond)) { failures++; printf("  FAIL: %s (line %d)\n", msg, __LINE__); } \
} while (0)

// The PID's register block, mapped by pid_Init through the wrapped cmn_Map
static uint32_t regs[1024];

int __wrap_cmn_Map(size_t size, size_t offset, void **mapped)
{
    (void)size;
    (void)offset;
    *mapped = regs;
    return RP_OK;
}

int __wrap_cmn_Unmap(size_t size, void **mapped)
{
    (void)size;
    *mapped = NULL;
    return RP_OK;
}

// No EEPROM: no calibration, as on a board whose calibration is unset
rp_calib_params_t calib_GetParams()
{
    rp_calib_params_t calib;
    memset(&calib, 0, sizeof(calib));
    return calib;
}

static uint32_t reg(uint32_t offset)
{
    return regs[offset / 4];
}

static int close_to(float a, float b, float tolerance)
{
    return fabsf(a - b) <= tolerance * fabsf(b) + 1e-12f;
}

int main(void)
{
    bool available = true;
    float value;
    rp_pset_mode_t mode;
    rp_dpin_t pin;
    rp_pidset_t active;
    bool holdoff, level, violated;
    rp_pid_counters_t counters;
    uint32_t unlocks[4];

    printf("test_pid\n");

    // The register map
    CHECK(sizeof(pid_control_t) == 0x240, "register block 0x240 bytes");
    CHECK(offsetof(pid_control_t, counters) == 0x200, "counters at 0x200");
    CHECK(offsetof(pid_control_t, pid11_setpoint) == 0x10, "setpoint at 0x10");
    CHECK(offsetof(pid_control_t, pid11_Kg) == 0xA0, "KG at 0xA0");
    CHECK(offsetof(pid_control_t, pid11_ext_reset_input) == 0xB0, "external reset input at 0xB0");
    CHECK(offsetof(pid_control_t, pset_ctrl) == 0xC0, "parameter set control at 0xC0");
    CHECK(offsetof(pid_control_t, holdoff) == 0xD0, "holdoff at 0xD0");
    CHECK(offsetof(pid_control_t, pset_status) == 0xF0, "status at 0xF0");
    CHECK(offsetof(pid_control_t, feature_id) == 0xFC, "feature ID at 0xFC");
    CHECK(offsetof(pid_control_t, set2) == 0x100, "set 2 at 0x100");

    // An FPGA image without the parameter sets
    memset(regs, 0, sizeof(regs));
    pid_Init();
    pid_HasParamSets(&available);
    CHECK(!available, "no parameter sets without the feature ID");
    CHECK(pid_SetPIDKp(RP_PID_11, 1.0f) == RP_OK, "set 1 KP without the parameter sets");
    CHECK(pid_SetParam(RP_PID_11, RP_PSET_2, RP_PID_KP, 1.0f) == RP_EUF, "set 2 refused");
    CHECK(pid_SetParam(RP_PID_11, RP_PSET_1, RP_PID_HOLDOFF, 1e-3f) == RP_EUF, "holdoff refused");
    CHECK(pid_SetParamSetMode(RP_PID_11, RP_PSET_MODE_HIGH_2) == RP_EUF, "set mode refused");
    CHECK(pid_GetParamSetState(RP_PID_11, &active, &holdoff, &level, &violated) == RP_EUF, "set state refused");
    CHECK(reg(0x120) == 0 && reg(0xC0) == 0 && reg(0xD0) == 0, "nothing written by the refused calls");
    CHECK(pid_GetCounters(RP_PID_11, &counters) == RP_EUF, "no counters without the feature ID");

    // The first image with the parameter sets, without the counters
    memset(regs, 0, sizeof(regs));
    regs[0xFC / 4] = 0x50530001;
    pid_Init();
    pid_HasParamSets(&available);
    CHECK(available, "parameter sets with feature version 1");
    CHECK(pid_GetCounters(RP_PID_11, &counters) == RP_EUF, "no counters with feature version 1");
    CHECK(pid_GetUnlockCounts(unlocks) == RP_EUF, "no unlock counts with feature version 1");

    // The counters: [counter][PID] at 0x200 + 0x10 * counter + 4 * PID
    memset(regs, 0, sizeof(regs));
    regs[0xFC / 4] = 0x50530002;
    for (int k = 0; k < 4; k++)
        for (int p = 0; p < 4; p++)
            regs[(0x200 + 0x10 * k + 4 * p) / 4] = 0x1000u * (k + 1) + p;
    pid_Init();
    CHECK(pid_GetCounters(RP_PID_21, &counters) == RP_OK, "counters with feature version 2");
    CHECK(counters.switches == 0x1002 && counters.holdoffs_went_outside == 0x2002
          && counters.holdoffs_ended_outside == 0x3002 && counters.unlocks == 0x4002, "the counters of PID 21");
    CHECK(pid_GetUnlockCounts(unlocks) == RP_OK && unlocks[0] == 0x4000 && unlocks[3] == 0x4003,
          "the unlock counts of all four");
    CHECK(pid_GetCounters(4, &counters) == RP_EPN, "PID 4 refused");

    // With the parameter sets
    memset(regs, 0, sizeof(regs));
    regs[0xFC / 4] = 0x50530002;
    pid_Init();
    pid_HasParamSets(&available);
    CHECK(available, "parameter sets with the feature ID");

    // The named functions address parameter set 1 at the addresses they always used
    for (rp_pid_t p = RP_PID_11; p <= RP_PID_22; p++) {
        uint32_t o = 4 * p;
        pid_SetPIDKp(p, 1.0f);           CHECK(reg(0x20 + o) == 4096, "KP 1.0 = 4096");
        pid_SetPIDKg(p, 0.5f);           CHECK(reg(0xA0 + o) == 2048, "KG 0.5 = 2048");
        pid_SetPIDKi(p, 1000.0f);        CHECK(reg(0x30 + o) == (uint32_t)round(1000.0f * (1 << 28) * 8e-9f), "KI");
        pid_SetPIDKii(p, 10.0f);         CHECK(reg(0x90 + o) == (uint32_t)round(10.0f * (1 << 28) * 8e-9f), "KII");
        pid_SetPIDKd(p, 1e-7f);          CHECK(reg(0x40 + o) == 3200, "KD 100 ns = 3200");
        pid_SetRelockMinimum(p, 0.7f);   CHECK(reg(0x50 + o) == 409, "window min 0.7 V");
        pid_SetRelockMaximum(p, 3.5f);   CHECK(reg(0x60 + o) == 2047, "window max 3.5 V");
        pid_SetPIDSetpoint(p, 0.5f);     CHECK(reg(0x10 + o) != 0, "setpoint written");
        CHECK(reg(0x110 + o) == 0 && reg(0x120 + o) == 0 && reg(0x1A0 + o) == 0, "set 2 untouched");
    }

    // Parameter set 2 at + 0x100, each parameter at its own register
    for (rp_pid_t p = RP_PID_11; p <= RP_PID_22; p++) {
        uint32_t o = 4 * p;
        pid_SetParam(p, RP_PSET_2, RP_PID_KP, 0.25f);         CHECK(reg(0x120 + o) == 1024, "set 2 KP");
        pid_SetParam(p, RP_PSET_2, RP_PID_KG, 2.0f);          CHECK(reg(0x1A0 + o) == 8192, "set 2 KG");
        pid_SetParam(p, RP_PSET_2, RP_PID_KI, 2000.0f);
        CHECK(reg(0x130 + o) == (uint32_t)round(2000.0f * (1 << 28) * 8e-9f), "set 2 KI");
        pid_SetParam(p, RP_PSET_2, RP_PID_KII, 20.0f);
        CHECK(reg(0x190 + o) == (uint32_t)round(20.0f * (1 << 28) * 8e-9f), "set 2 KII");
        pid_SetParam(p, RP_PSET_2, RP_PID_KD, 2e-7f);         CHECK(reg(0x140 + o) == 6400, "set 2 KD");
        pid_SetParam(p, RP_PSET_2, RP_PID_RELOCK_MIN, 1.4f);  CHECK(reg(0x150 + o) == 819, "set 2 window min");
        pid_SetParam(p, RP_PSET_2, RP_PID_RELOCK_MAX, 7.0f);  CHECK(reg(0x160 + o) == 4095, "set 2 window max");
        pid_SetParam(p, RP_PSET_2, RP_PID_SETPOINT, -0.25f);  CHECK(reg(0x110 + o) != reg(0x10 + o), "set 2 setpoint");
        pid_SetParam(p, RP_PSET_1, RP_PID_HOLDOFF, 1e-3f);     CHECK(reg(0xD0 + o) == 125000, "set 1 holdoff 1 ms");
        pid_SetParam(p, RP_PSET_2, RP_PID_HOLDOFF, 2e-6f);    CHECK(reg(0x1D0 + o) == 250, "set 2 holdoff 2 us");
        CHECK(reg(0x20 + o) == 4096 && reg(0xA0 + o) == 2048, "set 1 untouched");

        pid_GetParam(p, RP_PSET_2, RP_PID_KP, &value);         CHECK(value == 0.25f, "set 2 KP read back");
        pid_GetParam(p, RP_PSET_2, RP_PID_KI, &value);         CHECK(close_to(value, 2000.0f, 1e-3f), "set 2 KI read back");
        pid_GetParam(p, RP_PSET_2, RP_PID_KD, &value);         CHECK(close_to(value, 2e-7f, 1e-6f), "set 2 KD read back");
        pid_GetParam(p, RP_PSET_2, RP_PID_SETPOINT, &value);   CHECK(close_to(value, -0.25f, 1e-3f), "set 2 setpoint read back");
        pid_GetParam(p, RP_PSET_2, RP_PID_RELOCK_MAX, &value); CHECK(close_to(value, 7.0f, 1e-3f), "set 2 window max read back");
        pid_GetParam(p, RP_PSET_2, RP_PID_HOLDOFF, &value);    CHECK(close_to(value, 2e-6f, 1e-6f), "set 2 holdoff read back");
        pid_GetPIDKp(p, &value);                                 CHECK(value == 1.0f, "set 1 KP read back");
    }
    CHECK(pid_SetParam(RP_PID_11, RP_PSET_2, RP_PID_KP, -1.0f) == RP_EIPV, "negative gain refused");
    CHECK(pid_SetParam(RP_PID_11, RP_PSET_2, RP_PID_HOLDOFF, -1.0f) == RP_EIPV, "negative holdoff refused");
    pid_SetParam(RP_PID_11, RP_PSET_2, RP_PID_HOLDOFF, 100.0f);
    CHECK(reg(0x1D0) == 0xFFFFFFFF, "holdoff beyond 34 s clamped");
    CHECK(pid_SetParam(4, RP_PSET_1, RP_PID_KP, 1.0f) == RP_EPN, "PID 4 refused");
    CHECK(pid_SetParam(RP_PID_11, 2, RP_PID_KP, 1.0f) == RP_EIPV, "set index 2 refused");

    // Copy: the register values, all but the holdoff
    pid_CopyParams(RP_PID_21, RP_PSET_1, RP_PSET_2);
    CHECK(reg(0x128) == reg(0x28) && reg(0x1A8) == reg(0xA8) && reg(0x118) == reg(0x18)
          && reg(0x158) == reg(0x58) && reg(0x168) == reg(0x68) && reg(0x138) == reg(0x38)
          && reg(0x148) == reg(0x48) && reg(0x198) == reg(0x98), "copy set 1 to set 2");
    CHECK(reg(0x1D8) == 250 && reg(0xD8) == 125000, "holdoffs not copied");
    pid_SetParam(RP_PID_21, RP_PSET_2, RP_PID_KP, 0.125f);
    pid_CopyParams(RP_PID_21, RP_PSET_2, RP_PSET_1);
    CHECK(reg(0x28) == 512 && reg(0x128) == 512, "copy set 2 to set 1");
    CHECK(pid_SetParam(RP_PID_11, RP_PSET_2, RP_PID_KP, NAN) == RP_EIPV, "NaN gain refused");
    CHECK(pid_SetParam(RP_PID_11, RP_PSET_2, RP_PID_HOLDOFF, NAN) == RP_EIPV, "NaN holdoff refused");

    // Selection
    CHECK(pid_SetParamSetInput(RP_PID_12, RP_DIO5_N) == RP_OK, "input DIO5_N");
    CHECK(((reg(0xC4) >> 4) & 0x7) == 4, "DIO5_N is input 4");
    CHECK(pid_SetParamSetMode(RP_PID_12, RP_PSET_MODE_HIGH_1) == RP_OK && (reg(0xC4) & 0x3) == 3,
          "mode input high: set 1");
    CHECK(pid_SetParamSetMode(RP_PID_12, RP_PSET_MODE_HIGH_2) == RP_OK, "mode input high: set 2");
    CHECK((reg(0xC4) & 0x3) == 2 && ((reg(0xC4) >> 4) & 0x7) == 4, "mode beside the input");
    pid_GetParamSetMode(RP_PID_12, &mode);   CHECK(mode == RP_PSET_MODE_HIGH_2, "mode read back");
    pid_GetParamSetInput(RP_PID_12, &pin);   CHECK(pin == RP_DIO5_N, "input read back");
    CHECK(pid_SetParamSetInput(RP_PID_12, RP_DIO1_P) == RP_EPN, "an output pin refused");
    CHECK(pid_SetParamSetMode(RP_PID_12, 4) == RP_EIPV, "mode 4 refused");
    pid_SetParamSetInput(RP_PID_11, RP_DIO7_P);
    CHECK(((reg(0xC0) >> 4) & 0x7) == 2, "DIO7_P is input 2");

    // Status: PID 12 on set 1 in its holdoff, its input (4) high, PID 11 went outside the window
    regs[0xF0 / 4] = (1u << 1) | (1u << (4 + 1)) | (1u << (12 + 0)) | (1u << (16 + 4));
    pid_GetParamSetState(RP_PID_12, &active, &holdoff, &level, &violated);
    CHECK(active == RP_PSET_2 && holdoff && level && !violated, "PID 12 state");
    pid_GetParamSetState(RP_PID_11, &active, &holdoff, &level, &violated);
    CHECK(active == RP_PSET_1 && !holdoff && !level && violated, "PID 11 state");

    // External reset sources 2 and 3
    CHECK(pid_SetExtResetInput(RP_PID_11, RP_DIO7_P) == RP_OK && reg(0xB0) == 2, "external reset from DIO7_P");
    CHECK(pid_SetExtResetInput(RP_PID_11, RP_DIO0_N) == RP_OK && reg(0xB0) == 3, "external reset from DIO0_N");

    // Lock and scan: the integrator reset, hold and output enable bits of one
    // PID; the other flags stay
    bool lock;
    uint32_t conf = (0xFu << 28) | (0xFu << 20) | (0xAu << 16) | (0x3u << 8) | (0x5u << 4);
    regs[0] = conf;
    CHECK(pid_SetLock(RP_PID_21, false) == RP_OK, "scan");
    CHECK(reg(0x0) == ((conf & ~(1u << 22)) | (1u << 2) | (1u << 14)), "scan: reset and hold on, output off");
    pid_GetLock(RP_PID_21, &lock);      CHECK(!lock, "a scanning PID does not lock");
    pid_GetLock(RP_PID_11, &lock);      CHECK(lock, "the other PIDs still lock");
    CHECK(pid_SetLock(RP_PID_21, true) == RP_OK && reg(0x0) == conf, "lock: back to the start");
    pid_GetLock(RP_PID_21, &lock);      CHECK(lock, "a locking PID");
    regs[0] = conf | (1u << 13);
    pid_GetLock(RP_PID_12, &lock);      CHECK(!lock, "a held PID does not lock");
    regs[0] = conf & ~(1u << 23);
    pid_GetLock(RP_PID_22, &lock);      CHECK(!lock, "a PID with its output off does not lock");
    CHECK(pid_SetLock(4, true) == RP_EPN && pid_GetLock(4, &lock) == RP_EPN, "PID 4 refused");

    pid_Release();

    if (failures == 0)
        printf("PASS (%d checks)\n", checks);
    else
        printf("FAIL (%d of %d checks failed)\n", failures, checks);
    return failures != 0;
}
