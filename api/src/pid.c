/**
 * Copyright (c) 2018, Fabian Schmid
 * Copyright (c) 2023, 2026, Lothar Maisenbacher
 *
 * All rights reserved.
 *
 * $Id: $
 *
 * @brief Red Pitaya library pid module implementation
 *
 * @Author Red Pitaya
 *
 * (c) Red Pitaya  http://www.redpitaya.com
 *
 * This part of code is written in C programming language.
 * Please visit http://en.wikipedia.org/wiki/C_(programming_language)
 * for more details on the language used herein.
 */

#include <stdbool.h>
#include <math.h>
#include "common.h"
#include "pid.h"
#include "calib.h"

// The FPGA register structure for the PID
static volatile pid_control_t *pid_reg = NULL;
// The FPGA image has the two parameter sets
static bool pid_sets = false;
// The FPGA image has the event counters
static bool pid_counters = false;

// The inputs that can select the parameter set, in the order of the
// selection register
static const rp_dpin_t PID_PSET_INPUTS[] = {
    RP_DIO5_P, RP_DIO6_P, RP_DIO7_P, RP_DIO0_N, RP_DIO5_N, RP_DIO6_N, RP_DIO7_N
};
static const uint32_t PID_PSET_INPUT_COUNT = sizeof(PID_PSET_INPUTS) / sizeof(PID_PSET_INPUTS[0]);


/**
 * general
 */

int pid_Init()
{
    int ret = cmn_Map(PID_BASE_SIZE, PID_BASE_ADDR, (void**)&pid_reg);
    pid_sets = (ret == RP_OK) && (pid_reg != NULL)
               && ((pid_reg->feature_id >> 16) == PID_FEATURE_MAGIC);
    pid_counters = pid_sets && ((pid_reg->feature_id & 0xFFFF) >= PID_FEATURE_COUNTERS);
    return RP_OK;
}

int pid_Release()
{
    cmn_Unmap(PID_BASE_SIZE, (void**)&pid_reg);
    pid_sets = false;
    pid_counters = false;
    return RP_OK;
}

int pid_HasParamSets(bool *available)
{
    *available = pid_sets;
    return RP_OK;
}

/**
 * PID parameters, per parameter set
 */

// Register of a per-set parameter (PID_REG_* offset) of a PID and set
static volatile uint32_t *pid_SetRegister(uint32_t offset, rp_pid_t pid, rp_pidset_t set)
{
    return (volatile uint32_t *)((volatile uint8_t *)pid_reg + offset + 4 * pid + PID_SET_STRIDE * set);
}

static int pid_CheckSet(rp_pid_t pid, rp_pidset_t set, rp_pidparam_t param)
{
    if ((unsigned)pid > RP_PID_22)
        return RP_EPN;
    if ((unsigned)set > RP_PSET_2 || (unsigned)param > RP_PID_HOLDOFF)
        return RP_EIPV;
    // the holdoff and parameter set 2 exist only with the parameter sets
    if (!pid_sets && (set == RP_PSET_2 || param == RP_PID_HOLDOFF))
        return RP_EUF;
    return RP_OK;
}

int pid_SetParam(rp_pid_t pid, rp_pidset_t set, rp_pidparam_t param, float value)
{
    rp_calib_params_t calib;
    uint32_t counts;
    double cycles;
    int ret = pid_CheckSet(pid, set, param);
    if (ret != RP_OK)
        return ret;

    switch (param) {
        case RP_PID_SETPOINT:
            calib = calib_GetParams();
            if (pid == RP_PID_11 || pid == RP_PID_21)  // Input Channel A
                counts = cmn_CnvVToCnt(DATA_BIT_LENGTH, value, SETPOINT_MAX, false,
                    calib.fe_ch1_fs_g_hi, calib.fe_ch1_hi_offs, 0);
            else  // Input Channel B
                counts = cmn_CnvVToCnt(DATA_BIT_LENGTH, value, SETPOINT_MAX, false,
                    calib.fe_ch2_fs_g_hi, calib.fe_ch2_hi_offs, 0);
            return cmn_SetValue(pid_SetRegister(PID_REG_SETPOINT, pid, set), counts, PID_SETPOINT_MASK);

        case RP_PID_KP:
        case RP_PID_KG:
            if (!(value >= 0))  // negative, or NaN
                return RP_EIPV;
            counts = (int)round(value * (1 << PID_PSR));
            if (counts > PID_KP_MASK)  // check for integer overflow
                counts = PID_KP_MASK;
            return cmn_SetValue(pid_SetRegister(param == RP_PID_KP ? PID_REG_KP : PID_REG_KG, pid, set),
                                counts, PID_KP_MASK);

        case RP_PID_KI:
        case RP_PID_KII:
            if (!(value >= 0))  // negative, or NaN
                return RP_EIPV;
            counts = (int)round(value * (1 << PID_ISR) * PID_TIMESTEP);
            if (counts > PID_KI_MASK) // check for integer overflow
                counts = PID_KI_MASK;
            return cmn_SetValue(pid_SetRegister(param == RP_PID_KI ? PID_REG_KI : PID_REG_KII, pid, set),
                                counts, PID_KI_MASK);

        case RP_PID_KD:
            if (!(value >= 0))  // negative, or NaN
                return RP_EIPV;
            counts = (int)round(value * (1 << PID_DSR) / PID_TIMESTEP);
            if (counts > PID_KD_MASK) // check for integer overflow
                counts = PID_KD_MASK;
            return cmn_SetValue(pid_SetRegister(PID_REG_KD, pid, set), counts, PID_KD_MASK);

        case RP_PID_RELOCK_MIN:
        case RP_PID_RELOCK_MAX:
            counts = (uint32_t) ((value - ANALOG_IN_MIN_VAL) / (ANALOG_IN_MAX_VAL - ANALOG_IN_MIN_VAL) * ANALOG_IN_MAX_VAL_INTEGER);
            return cmn_SetValue(pid_SetRegister(param == RP_PID_RELOCK_MIN ? PID_REG_RELOCK_MIN : PID_REG_RELOCK_MAX,
                                                pid, set),
                                counts, PID_RELOCK_MASK);

        case RP_PID_HOLDOFF:
            if (!(value >= 0))  // negative, or NaN
                return RP_EIPV;
            cycles = round((double)value / PID_TIMESTEP);
            counts = (cycles > 4294967295.0) ? 0xFFFFFFFF : (uint32_t)cycles;
            *pid_SetRegister(PID_REG_HOLDOFF, pid, set) = counts;
            return RP_OK;

        default:
            return RP_EIPV;
    }
}

int pid_GetParam(rp_pid_t pid, rp_pidset_t set, rp_pidparam_t param, float *value)
{
    rp_calib_params_t calib;
    uint32_t counts;
    int ret = pid_CheckSet(pid, set, param);
    if (ret != RP_OK)
        return ret;

    switch (param) {
        case RP_PID_SETPOINT:
            calib = calib_GetParams();
            cmn_GetValue(pid_SetRegister(PID_REG_SETPOINT, pid, set), &counts, PID_SETPOINT_MASK);
            if (pid == RP_PID_11 || pid == RP_PID_21)  // Input Channel A
                *value = cmn_CnvCntToV(DATA_BIT_LENGTH, counts, SETPOINT_MAX,
                    calib.fe_ch1_fs_g_hi, calib.fe_ch1_hi_offs, 0);
            else  // Input Channel B
                *value = cmn_CnvCntToV(DATA_BIT_LENGTH, counts, SETPOINT_MAX,
                    calib.fe_ch2_fs_g_hi, calib.fe_ch2_hi_offs, 0);
            return RP_OK;

        case RP_PID_KP:
        case RP_PID_KG:
            cmn_GetValue(pid_SetRegister(param == RP_PID_KP ? PID_REG_KP : PID_REG_KG, pid, set),
                         &counts, PID_KP_MASK);
            *value = (float)counts/(1 << PID_PSR);
            return RP_OK;

        case RP_PID_KI:
        case RP_PID_KII:
            cmn_GetValue(pid_SetRegister(param == RP_PID_KI ? PID_REG_KI : PID_REG_KII, pid, set),
                         &counts, PID_KI_MASK);
            *value = (float)counts/(PID_TIMESTEP * (1 << PID_ISR));
            return RP_OK;

        case RP_PID_KD:
            cmn_GetValue(pid_SetRegister(PID_REG_KD, pid, set), &counts, PID_KD_MASK);
            *value = (float)counts * PID_TIMESTEP / (1 << PID_DSR);
            return RP_OK;

        case RP_PID_RELOCK_MIN:
        case RP_PID_RELOCK_MAX:
            cmn_GetValue(pid_SetRegister(param == RP_PID_RELOCK_MIN ? PID_REG_RELOCK_MIN : PID_REG_RELOCK_MAX,
                                         pid, set),
                         &counts, PID_RELOCK_MASK);
            *value = (float)counts / ANALOG_IN_MAX_VAL_INTEGER * (ANALOG_IN_MAX_VAL - ANALOG_IN_MIN_VAL) + ANALOG_IN_MIN_VAL;
            return RP_OK;

        case RP_PID_HOLDOFF:
            counts = *pid_SetRegister(PID_REG_HOLDOFF, pid, set);
            *value = (float)((double)counts * PID_TIMESTEP);
            return RP_OK;

        default:
            return RP_EIPV;
    }
}

int pid_CopyParams(rp_pid_t pid, rp_pidset_t from, rp_pidset_t to)
{
    // The register values, so the copy is exact. Not the holdoff: each set's
    // holdoff belongs to the switch into that set.
    const uint32_t offsets[] = {
        PID_REG_SETPOINT, PID_REG_KP, PID_REG_KI, PID_REG_KD, PID_REG_RELOCK_MIN,
        PID_REG_RELOCK_MAX, PID_REG_KII, PID_REG_KG
    };
    int ret = pid_CheckSet(pid, from, RP_PID_HOLDOFF);
    if (ret == RP_OK)
        ret = pid_CheckSet(pid, to, RP_PID_HOLDOFF);
    if (ret != RP_OK)
        return ret;
    for (unsigned i = 0; i < sizeof(offsets) / sizeof(offsets[0]); i++)
        *pid_SetRegister(offsets[i], pid, to) = *pid_SetRegister(offsets[i], pid, from);
    return RP_OK;
}

/**
 * PID parameters of parameter set 1, the only set before parameter sets
 * existed
 */
int pid_SetPIDSetpoint(rp_pid_t pid, float setpoint)
{
    return pid_SetParam(pid, RP_PSET_1, RP_PID_SETPOINT, setpoint);
}

int pid_GetPIDSetpoint(rp_pid_t pid, float *setpoint)
{
    return pid_GetParam(pid, RP_PSET_1, RP_PID_SETPOINT, setpoint);
}

int pid_SetPIDKp(rp_pid_t pid, float kp)
{
    return pid_SetParam(pid, RP_PSET_1, RP_PID_KP, kp);
}

int pid_GetPIDKp(rp_pid_t pid, float *kp)
{
    return pid_GetParam(pid, RP_PSET_1, RP_PID_KP, kp);
}

int pid_SetPIDKi(rp_pid_t pid, float ki)
{
    return pid_SetParam(pid, RP_PSET_1, RP_PID_KI, ki);
}

int pid_GetPIDKi(rp_pid_t pid, float *ki)
{
    return pid_GetParam(pid, RP_PSET_1, RP_PID_KI, ki);
}

int pid_SetPIDKd(rp_pid_t pid, float kd)
{
    return pid_SetParam(pid, RP_PSET_1, RP_PID_KD, kd);
}

int pid_GetPIDKd(rp_pid_t pid, float *kd)
{
    return pid_GetParam(pid, RP_PSET_1, RP_PID_KD, kd);
}

int pid_SetPIDKii(rp_pid_t pid, float kii)
{
    return pid_SetParam(pid, RP_PSET_1, RP_PID_KII, kii);
}

int pid_GetPIDKii(rp_pid_t pid, float *kii)
{
    return pid_GetParam(pid, RP_PSET_1, RP_PID_KII, kii);
}

int pid_SetPIDKg(rp_pid_t pid, float kg)
{
    return pid_SetParam(pid, RP_PSET_1, RP_PID_KG, kg);
}

int pid_GetPIDKg(rp_pid_t pid, float *kg)
{
    return pid_GetParam(pid, RP_PSET_1, RP_PID_KG, kg);
}

int pid_SetPIDIntReset(rp_pid_t pid, bool enable) {
    if(enable) {
        switch(pid) {
            case RP_PID_11: return cmn_SetBits(&pid_reg->conf, 0x1, PID_CONF_MASK);
            case RP_PID_12: return cmn_SetBits(&pid_reg->conf, 0x1 << 1, PID_CONF_MASK);
            case RP_PID_21: return cmn_SetBits(&pid_reg->conf, 0x1 << 2, PID_CONF_MASK);
            case RP_PID_22: return cmn_SetBits(&pid_reg->conf, 0x1 << 3, PID_CONF_MASK);
            default: return RP_EPN;
        }
    }
    else {
        switch(pid) {
            case RP_PID_11: return cmn_UnsetBits(&pid_reg->conf, 0x1, PID_CONF_MASK);
            case RP_PID_12: return cmn_UnsetBits(&pid_reg->conf, 0x1 << 1, PID_CONF_MASK);
            case RP_PID_21: return cmn_UnsetBits(&pid_reg->conf, 0x1 << 2, PID_CONF_MASK);
            case RP_PID_22: return cmn_UnsetBits(&pid_reg->conf, 0x1 << 3, PID_CONF_MASK);
            default: return RP_EPN;
        }
    }
}
int pid_GetPIDIntReset(rp_pid_t pid, bool *enabled) {
    switch(pid) {
        case RP_PID_11: return cmn_AreBitsSet(pid_reg->conf, 0x1, PID_CONF_MASK, enabled);
        case RP_PID_12: return cmn_AreBitsSet(pid_reg->conf, 0x1 << 1, PID_CONF_MASK, enabled);
        case RP_PID_21: return cmn_AreBitsSet(pid_reg->conf, 0x1 << 2, PID_CONF_MASK, enabled);
        case RP_PID_22: return cmn_AreBitsSet(pid_reg->conf, 0x1 << 3, PID_CONF_MASK, enabled);
        default: return RP_EPN;
    }
}

int pid_SetPIDInverted(rp_pid_t pid, bool inverted) {
    if(inverted) {
        switch(pid) {
            case RP_PID_11: return cmn_SetBits(&pid_reg->conf, 0x1 << 4, PID_CONF_MASK);
            case RP_PID_12: return cmn_SetBits(&pid_reg->conf, 0x1 << 5, PID_CONF_MASK);
            case RP_PID_21: return cmn_SetBits(&pid_reg->conf, 0x1 << 6, PID_CONF_MASK);
            case RP_PID_22: return cmn_SetBits(&pid_reg->conf, 0x1 << 7, PID_CONF_MASK);
            default: return RP_EPN;
        }
    }
    else {
        switch(pid) {
            case RP_PID_11: return cmn_UnsetBits(&pid_reg->conf, 0x1 << 4, PID_CONF_MASK);
            case RP_PID_12: return cmn_UnsetBits(&pid_reg->conf, 0x1 << 5, PID_CONF_MASK);
            case RP_PID_21: return cmn_UnsetBits(&pid_reg->conf, 0x1 << 6, PID_CONF_MASK);
            case RP_PID_22: return cmn_UnsetBits(&pid_reg->conf, 0x1 << 7, PID_CONF_MASK);
            default: return RP_EPN;
        }
    }
}

int pid_GetPIDInverted(rp_pid_t pid, bool *inverted) {
    switch(pid) {
        case RP_PID_11: return cmn_AreBitsSet(pid_reg->conf, 0x1 << 4, PID_CONF_MASK, inverted);
        case RP_PID_12: return cmn_AreBitsSet(pid_reg->conf, 0x1 << 5, PID_CONF_MASK, inverted);
        case RP_PID_21: return cmn_AreBitsSet(pid_reg->conf, 0x1 << 6, PID_CONF_MASK, inverted);
        case RP_PID_22: return cmn_AreBitsSet(pid_reg->conf, 0x1 << 7, PID_CONF_MASK, inverted);
        default: return RP_EPN;
    }
}

int pid_SetResetWhenRailed(rp_pid_t pid, bool enable) {
    if(enable) {
        switch(pid) {
            case RP_PID_11: return cmn_SetBits(&pid_reg->conf, 0x1 << 8, PID_CONF_MASK);
            case RP_PID_12: return cmn_SetBits(&pid_reg->conf, 0x1 << 9, PID_CONF_MASK);
            case RP_PID_21: return cmn_SetBits(&pid_reg->conf, 0x1 << 10, PID_CONF_MASK);
            case RP_PID_22: return cmn_SetBits(&pid_reg->conf, 0x1 << 11, PID_CONF_MASK);
            default: return RP_EPN;
        }
    }
    else {
        switch(pid) {
            case RP_PID_11: return cmn_UnsetBits(&pid_reg->conf, 0x1 << 8, PID_CONF_MASK);
            case RP_PID_12: return cmn_UnsetBits(&pid_reg->conf, 0x1 << 9, PID_CONF_MASK);
            case RP_PID_21: return cmn_UnsetBits(&pid_reg->conf, 0x1 << 10, PID_CONF_MASK);
            case RP_PID_22: return cmn_UnsetBits(&pid_reg->conf, 0x1 << 11, PID_CONF_MASK);
            default: return RP_EPN;
        }
    }
}
int pid_GetResetWhenRailed(rp_pid_t pid, bool *enabled) {
    switch(pid) {
        case RP_PID_11: return cmn_AreBitsSet(pid_reg->conf, 0x1 << 8, PID_CONF_MASK, enabled);
        case RP_PID_12: return cmn_AreBitsSet(pid_reg->conf, 0x1 << 9, PID_CONF_MASK, enabled);
        case RP_PID_21: return cmn_AreBitsSet(pid_reg->conf, 0x1 << 10, PID_CONF_MASK, enabled);
        case RP_PID_22: return cmn_AreBitsSet(pid_reg->conf, 0x1 << 11, PID_CONF_MASK, enabled);
        default: return RP_EPN;
    }
}

int pid_SetHold(rp_pid_t pid, bool enable) {
    if(pid > RP_PID_22)
        return RP_EPN;
    if(enable)
        return cmn_SetBits(&pid_reg->conf, 0x1 << (PID_CONF_HOLD_SHIFT + pid), PID_CONF_MASK);
    else
        return cmn_UnsetBits(&pid_reg->conf, 0x1 << (PID_CONF_HOLD_SHIFT + pid), PID_CONF_MASK);
}

int pid_GetHold(rp_pid_t pid, bool *enabled) {
    if(pid > RP_PID_22)
        return RP_EPN;
    return cmn_AreBitsSet(pid_reg->conf, 0x1 << (PID_CONF_HOLD_SHIFT + pid), PID_CONF_MASK, enabled);
}

int pid_SetPIDRelock(rp_pid_t pid, bool enable) {
    if(enable) {
        switch(pid) {
            case RP_PID_11: return cmn_SetBits(&pid_reg->conf, 0x1 << 16, PID_CONF_MASK);
            case RP_PID_12: return cmn_SetBits(&pid_reg->conf, 0x1 << 17, PID_CONF_MASK);
            case RP_PID_21: return cmn_SetBits(&pid_reg->conf, 0x1 << 18, PID_CONF_MASK);
            case RP_PID_22: return cmn_SetBits(&pid_reg->conf, 0x1 << 19, PID_CONF_MASK);
            default: return RP_EPN;
        }
    }
    else {
        switch(pid) {
            case RP_PID_11: return cmn_UnsetBits(&pid_reg->conf, 0x1 << 16, PID_CONF_MASK);
            case RP_PID_12: return cmn_UnsetBits(&pid_reg->conf, 0x1 << 17, PID_CONF_MASK);
            case RP_PID_21: return cmn_UnsetBits(&pid_reg->conf, 0x1 << 18, PID_CONF_MASK);
            case RP_PID_22: return cmn_UnsetBits(&pid_reg->conf, 0x1 << 19, PID_CONF_MASK);
            default: return RP_EPN;
        }
    }
}

int pid_GetPIDRelock(rp_pid_t pid, bool *enabled) {
    switch(pid) {
        case RP_PID_11: return cmn_AreBitsSet(pid_reg->conf, 0x1 << 16, PID_CONF_MASK, enabled);
        case RP_PID_12: return cmn_AreBitsSet(pid_reg->conf, 0x1 << 17, PID_CONF_MASK, enabled);
        case RP_PID_21: return cmn_AreBitsSet(pid_reg->conf, 0x1 << 18, PID_CONF_MASK, enabled);
        case RP_PID_22: return cmn_AreBitsSet(pid_reg->conf, 0x1 << 19, PID_CONF_MASK, enabled);
        default: return RP_EPN;
    }
}

int pid_SetPIDEnable(rp_pid_t pid, bool enable) {
    if(enable) {
        switch(pid) {
            case RP_PID_11: return cmn_SetBits(&pid_reg->conf, 0x1 << 20, PID_CONF_MASK);
            case RP_PID_12: return cmn_SetBits(&pid_reg->conf, 0x1 << 21, PID_CONF_MASK);
            case RP_PID_21: return cmn_SetBits(&pid_reg->conf, 0x1 << 22, PID_CONF_MASK);
            case RP_PID_22: return cmn_SetBits(&pid_reg->conf, 0x1 << 23, PID_CONF_MASK);
            default: return RP_EPN;
        }
    }
    else {
        switch(pid) {
            case RP_PID_11: return cmn_UnsetBits(&pid_reg->conf, 0x1 << 20, PID_CONF_MASK);
            case RP_PID_12: return cmn_UnsetBits(&pid_reg->conf, 0x1 << 21, PID_CONF_MASK);
            case RP_PID_21: return cmn_UnsetBits(&pid_reg->conf, 0x1 << 22, PID_CONF_MASK);
            case RP_PID_22: return cmn_UnsetBits(&pid_reg->conf, 0x1 << 23, PID_CONF_MASK);
            default: return RP_EPN;
        }
    }
}

int pid_GetPIDEnable(rp_pid_t pid, bool *enabled) {
    switch(pid) {
        case RP_PID_11: return cmn_AreBitsSet(pid_reg->conf, 0x1 << 20, PID_CONF_MASK, enabled);
        case RP_PID_12: return cmn_AreBitsSet(pid_reg->conf, 0x1 << 21, PID_CONF_MASK, enabled);
        case RP_PID_21: return cmn_AreBitsSet(pid_reg->conf, 0x1 << 22, PID_CONF_MASK, enabled);
        case RP_PID_22: return cmn_AreBitsSet(pid_reg->conf, 0x1 << 23, PID_CONF_MASK, enabled);
        default: return RP_EPN;
    }
}

int pid_GetPIDLockStatus(rp_pid_t pid, bool *lock_status) {
    if(pid > RP_PID_22)
        return RP_EPN;
    return cmn_AreBitsSet(pid_reg->conf, 0x1 << (PID_CONF_LOCKED_SHIFT + pid), PID_CONF_MASK, lock_status);
}

int pid_GetLockHoldBits(uint8_t *locked, uint8_t *held) {
    // One read of the configuration word: the four lock flags and the
    // four hold flags come from the same instant (the lockbox monitor polls
    // this once per millisecond)
    uint32_t conf = pid_reg->conf;
    *locked = (conf >> PID_CONF_LOCKED_SHIFT) & 0xF;
    *held = (conf >> PID_CONF_HOLD_SHIFT) & 0xF;
    return RP_OK;
}

int pid_SetLock(rp_pid_t pid, bool lock) {
    if(pid > RP_PID_22)
        return RP_EPN;
    // Integrator reset, hold and output enable change in one write, so they
    // take effect in the same clock cycle
    uint32_t reset = 0x1 << (PID_CONF_INT_RESET_SHIFT + pid);
    uint32_t hold = 0x1 << (PID_CONF_HOLD_SHIFT + pid);
    uint32_t enable = 0x1 << (PID_CONF_ENABLE_SHIFT + pid);
    uint32_t conf = pid_reg->conf & ~(reset | hold | enable);
    pid_reg->conf = conf | (lock ? enable : (reset | hold));
    return RP_OK;
}

int pid_GetCounters(rp_pid_t pid, rp_pid_counters_t *counters) {
    if(pid > RP_PID_22)
        return RP_EPN;
    if(!pid_counters)
        return RP_EUF;
    counters->switches = pid_reg->counters[PID_CNT_SWITCHES][pid];
    counters->holdoffs_left = pid_reg->counters[PID_CNT_HOLDOFFS_LEFT][pid];
    counters->holdoffs_out = pid_reg->counters[PID_CNT_HOLDOFFS_OUT][pid];
    counters->unlocks = pid_reg->counters[PID_CNT_UNLOCKS][pid];
    return RP_OK;
}

int pid_GetUnlockCounts(uint32_t unlocks[4]) {
    if(!pid_counters)
        return RP_EUF;
    for(int i = 0; i < 4; i++)
        unlocks[i] = pid_reg->counters[PID_CNT_UNLOCKS][i];
    return RP_OK;
}

int pid_GetLock(rp_pid_t pid, bool *lock) {
    if(pid > RP_PID_22)
        return RP_EPN;
    uint32_t conf = pid_reg->conf;
    *lock = !((conf >> (PID_CONF_INT_RESET_SHIFT + pid)) & 0x1)
            && !((conf >> (PID_CONF_HOLD_SHIFT + pid)) & 0x1)
            && ((conf >> (PID_CONF_ENABLE_SHIFT + pid)) & 0x1);
    return RP_OK;
}

int pid_SetRelockStepsize(rp_pid_t pid, float stepsize) {
    uint32_t stepsize_integer;

    if(stepsize < 0)
        return RP_EIPV;

    stepsize_integer = (int)round(stepsize * (1 << PID_STEPSR) * PID_TIMESTEP/PID_DACCOUNT);
    if(stepsize_integer > PID_STEPSIZE_MASK) // check for integer overflow
        stepsize_integer = PID_STEPSIZE_MASK;

    switch (pid) {
        case RP_PID_11: return cmn_SetValue(&pid_reg->relock11_stepsize,
                                            stepsize_integer, PID_STEPSIZE_MASK);
        case RP_PID_12: return cmn_SetValue(&pid_reg->relock12_stepsize,
                                            stepsize_integer, PID_STEPSIZE_MASK);
        case RP_PID_21: return cmn_SetValue(&pid_reg->relock21_stepsize,
                                            stepsize_integer, PID_STEPSIZE_MASK);
        case RP_PID_22: return cmn_SetValue(&pid_reg->relock22_stepsize,
                                            stepsize_integer, PID_STEPSIZE_MASK);
        default: return RP_EPN;
    }
}

int pid_GetRelockStepsize(rp_pid_t pid, float *stepsize) {
    uint32_t stepsize_integer;
    switch(pid) {
        case RP_PID_11:
            cmn_GetValue(&pid_reg->relock11_stepsize, &stepsize_integer, PID_STEPSIZE_MASK);
            break;
        case RP_PID_12:
            cmn_GetValue(&pid_reg->relock12_stepsize, &stepsize_integer, PID_STEPSIZE_MASK);
            break;
        case RP_PID_21:
            cmn_GetValue(&pid_reg->relock21_stepsize, &stepsize_integer, PID_STEPSIZE_MASK);
            break;
        case RP_PID_22:
            cmn_GetValue(&pid_reg->relock22_stepsize, &stepsize_integer, PID_STEPSIZE_MASK);
            break;
        default: return RP_EPN;
    }

    *stepsize = (float)stepsize_integer*PID_DACCOUNT/(PID_TIMESTEP * (1 << PID_STEPSR));
    return RP_OK;
}

int pid_SetRelockMinimum(rp_pid_t pid, float minimum) {
    return pid_SetParam(pid, RP_PSET_1, RP_PID_RELOCK_MIN, minimum);
}

int pid_GetRelockMinimum(rp_pid_t pid, float *minimum) {
    return pid_GetParam(pid, RP_PSET_1, RP_PID_RELOCK_MIN, minimum);
}

int pid_SetRelockMaximum(rp_pid_t pid, float maximum) {
    return pid_SetParam(pid, RP_PSET_1, RP_PID_RELOCK_MAX, maximum);
}

int pid_GetRelockMaximum(rp_pid_t pid, float *maximum) {
    return pid_GetParam(pid, RP_PSET_1, RP_PID_RELOCK_MAX, maximum);
}

int pid_SetRelockInput(rp_pid_t pid, rp_apin_t pin) {
    if (pin > RP_AIN3)
        return RP_EPN;
    switch(pid) {
        case RP_PID_11: return cmn_SetValue(&pid_reg->relock11_input, pin-RP_AIN0, PID_RELOCK_INPUT_MASK);
        case RP_PID_12: return cmn_SetValue(&pid_reg->relock12_input, pin-RP_AIN0, PID_RELOCK_INPUT_MASK);
        case RP_PID_21: return cmn_SetValue(&pid_reg->relock21_input, pin-RP_AIN0, PID_RELOCK_INPUT_MASK);
        case RP_PID_22: return cmn_SetValue(&pid_reg->relock22_input, pin-RP_AIN0, PID_RELOCK_INPUT_MASK);
        default: return RP_EPN;
    }
    return RP_OK;
}
int pid_GetRelockInput(rp_pid_t pid, rp_apin_t *pin) {
    rp_apin_t tmp_pin;
    switch(pid) {
        case RP_PID_11:
            cmn_GetValue(&pid_reg->relock11_input, &tmp_pin, PID_RELOCK_INPUT_MASK);
            break;
        case RP_PID_12:
            cmn_GetValue(&pid_reg->relock12_input, &tmp_pin, PID_RELOCK_INPUT_MASK);
            break;
        case RP_PID_21:
            cmn_GetValue(&pid_reg->relock21_input, &tmp_pin, PID_RELOCK_INPUT_MASK);
            break;
        case RP_PID_22:
            cmn_GetValue(&pid_reg->relock22_input, &tmp_pin, PID_RELOCK_INPUT_MASK);
            break;
        default: return RP_EPN;
    }
    *pin = tmp_pin+RP_AIN0;
    return RP_OK;
}

int pid_SetLockStatusOutputEnable(rp_pid_t pid, bool enable) {
    if(enable) {
        switch(pid) {
            case RP_PID_11: return cmn_SetBits(&pid_reg->conf, 0x1 << 28, PID_CONF_MASK);
            case RP_PID_12: return cmn_SetBits(&pid_reg->conf, 0x1 << 29, PID_CONF_MASK);
            case RP_PID_21: return cmn_SetBits(&pid_reg->conf, 0x1 << 30, PID_CONF_MASK);
            case RP_PID_22: return cmn_SetBits(&pid_reg->conf, 0x1 << 31, PID_CONF_MASK);
            default: return RP_EPN;
        }
    }
    else {
        switch(pid) {
            case RP_PID_11: return cmn_UnsetBits(&pid_reg->conf, 0x1 << 28, PID_CONF_MASK);
            case RP_PID_12: return cmn_UnsetBits(&pid_reg->conf, 0x1 << 29, PID_CONF_MASK);
            case RP_PID_21: return cmn_UnsetBits(&pid_reg->conf, 0x1 << 30, PID_CONF_MASK);
            case RP_PID_22: return cmn_UnsetBits(&pid_reg->conf, 0x1 << 31, PID_CONF_MASK);
            default: return RP_EPN;
        }
    }
}

int pid_GetLockStatusOutputEnable(rp_pid_t pid, bool *enabled) {
    switch(pid) {
        case RP_PID_11: return cmn_AreBitsSet(pid_reg->conf, 0x1 << 28, PID_CONF_MASK, enabled);
        case RP_PID_12: return cmn_AreBitsSet(pid_reg->conf, 0x1 << 29, PID_CONF_MASK, enabled);
        case RP_PID_21: return cmn_AreBitsSet(pid_reg->conf, 0x1 << 30, PID_CONF_MASK, enabled);
        case RP_PID_22: return cmn_AreBitsSet(pid_reg->conf, 0x1 << 31, PID_CONF_MASK, enabled);
        default: return RP_EPN;
    }
}

int pid_SetExtResetEnable(rp_pid_t pid, bool enable) {
    if(enable) {
        switch(pid) {
            case RP_PID_11: return cmn_SetBits(&pid_reg->conf2, 0x1, PID_CONF2_MASK);
            case RP_PID_12: return cmn_SetBits(&pid_reg->conf2, 0x1 << 1, PID_CONF2_MASK);
            case RP_PID_21: return cmn_SetBits(&pid_reg->conf2, 0x1 << 2, PID_CONF2_MASK);
            case RP_PID_22: return cmn_SetBits(&pid_reg->conf2, 0x1 << 3, PID_CONF2_MASK);
            default: return RP_EPN;
        }
    }
    else {
        switch(pid) {
            case RP_PID_11: return cmn_UnsetBits(&pid_reg->conf2, 0x1, PID_CONF2_MASK);
            case RP_PID_12: return cmn_UnsetBits(&pid_reg->conf2, 0x1 << 1, PID_CONF2_MASK);
            case RP_PID_21: return cmn_UnsetBits(&pid_reg->conf2, 0x1 << 2, PID_CONF2_MASK);
            case RP_PID_22: return cmn_UnsetBits(&pid_reg->conf2, 0x1 << 3, PID_CONF2_MASK);
            default: return RP_EPN;
        }
    }
}

int pid_GetExtResetEnable(rp_pid_t pid, bool *enabled) {
    switch(pid) {
        case RP_PID_11: return cmn_AreBitsSet(pid_reg->conf2, 0x1, PID_CONF2_MASK, enabled);
        case RP_PID_12: return cmn_AreBitsSet(pid_reg->conf2, 0x1 << 1, PID_CONF2_MASK, enabled);
        case RP_PID_21: return cmn_AreBitsSet(pid_reg->conf2, 0x1 << 2, PID_CONF2_MASK, enabled);
        case RP_PID_22: return cmn_AreBitsSet(pid_reg->conf2, 0x1 << 3, PID_CONF2_MASK, enabled);
        default: return RP_EPN;
    }
}

int pid_SetExtResetInput(rp_pid_t pid, rp_dpin_t pin) {
    if (pin > RP_DIO7_N)
        return RP_EPN;
    switch(pid) {
        case RP_PID_11: return cmn_SetValue(&pid_reg->pid11_ext_reset_input, pin-RP_DIO5_P, PID_EXT_RESET_INPUT_MASK);
        case RP_PID_12: return cmn_SetValue(&pid_reg->pid12_ext_reset_input, pin-RP_DIO5_P, PID_EXT_RESET_INPUT_MASK);
        case RP_PID_21: return cmn_SetValue(&pid_reg->pid21_ext_reset_input, pin-RP_DIO5_P, PID_EXT_RESET_INPUT_MASK);
        case RP_PID_22: return cmn_SetValue(&pid_reg->pid22_ext_reset_input, pin-RP_DIO5_P, PID_EXT_RESET_INPUT_MASK);
        default: return RP_EPN;
    }
    return RP_OK;
}
int pid_GetExtResetInput(rp_pid_t pid, rp_dpin_t *pin) {
    rp_dpin_t tmp_pin;
    switch(pid) {
        case RP_PID_11:
            cmn_GetValue(&pid_reg->pid11_ext_reset_input, &tmp_pin, PID_EXT_RESET_INPUT_MASK);
            break;
        case RP_PID_12:
            cmn_GetValue(&pid_reg->pid12_ext_reset_input, &tmp_pin, PID_EXT_RESET_INPUT_MASK);
            break;
        case RP_PID_21:
            cmn_GetValue(&pid_reg->pid21_ext_reset_input, &tmp_pin, PID_EXT_RESET_INPUT_MASK);
            break;
        case RP_PID_22:
            cmn_GetValue(&pid_reg->pid22_ext_reset_input, &tmp_pin, PID_EXT_RESET_INPUT_MASK);
            break;
        default: return RP_EPN;
    }
    *pin = tmp_pin+RP_DIO5_P;
    return RP_OK;
}

/**
 * Parameter set selection
 */

static int pid_CheckParamSets(rp_pid_t pid)
{
    if ((unsigned)pid > RP_PID_22)
        return RP_EPN;
    if (!pid_sets)
        return RP_EUF;
    return RP_OK;
}

int pid_SetParamSetMode(rp_pid_t pid, rp_pset_mode_t mode) {
    int ret = pid_CheckParamSets(pid);
    if (ret != RP_OK)
        return ret;
    if ((unsigned)mode > RP_PSET_MODE_HIGH_1)
        return RP_EIPV;
    return cmn_SetShiftedValue(&pid_reg->pset_ctrl[pid], mode, PID_PSET_MODE_MASK, 0);
}

int pid_GetParamSetMode(rp_pid_t pid, rp_pset_mode_t *mode) {
    uint32_t value;
    int ret = pid_CheckParamSets(pid);
    if (ret != RP_OK)
        return ret;
    cmn_GetShiftedValue(&pid_reg->pset_ctrl[pid], &value, PID_PSET_MODE_MASK, 0);
    *mode = value;
    return RP_OK;
}

int pid_SetParamSetInput(rp_pid_t pid, rp_dpin_t pin) {
    int ret = pid_CheckParamSets(pid);
    if (ret != RP_OK)
        return ret;
    for (uint32_t i = 0; i < PID_PSET_INPUT_COUNT; i++) {
        if (PID_PSET_INPUTS[i] == pin)
            return cmn_SetShiftedValue(&pid_reg->pset_ctrl[pid], i, PID_PSET_INPUT_MASK, PID_PSET_INPUT_SHIFT);
    }
    return RP_EPN;
}

int pid_GetParamSetInput(rp_pid_t pid, rp_dpin_t *pin) {
    uint32_t index;
    int ret = pid_CheckParamSets(pid);
    if (ret != RP_OK)
        return ret;
    cmn_GetShiftedValue(&pid_reg->pset_ctrl[pid], &index, PID_PSET_INPUT_MASK, PID_PSET_INPUT_SHIFT);
    if (index >= PID_PSET_INPUT_COUNT)
        return RP_EPN;
    *pin = PID_PSET_INPUTS[index];
    return RP_OK;
}

int pid_GetParamSetState(rp_pid_t pid, rp_pidset_t *active, bool *holdoff, bool *level, bool *violated) {
    uint32_t status;
    uint32_t index;
    int ret = pid_CheckParamSets(pid);
    if (ret != RP_OK)
        return ret;
    status = pid_reg->pset_status;
    cmn_GetShiftedValue(&pid_reg->pset_ctrl[pid], &index, PID_PSET_INPUT_MASK, PID_PSET_INPUT_SHIFT);
    *active = ((status >> (PID_STATUS_ACTIVE_SHIFT + pid)) & 0x1) ? RP_PSET_2 : RP_PSET_1;
    *holdoff = (status >> (PID_STATUS_HOLDOFF_SHIFT + pid)) & 0x1;
    *violated = (status >> (PID_STATUS_VIOLATED_SHIFT + pid)) & 0x1;
    *level = (index < PID_PSET_INPUT_COUNT) && ((status >> (PID_STATUS_LEVEL_SHIFT + index)) & 0x1);
    return RP_OK;
}
