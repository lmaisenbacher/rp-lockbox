/**
 * Copyright (c) 2018, Fabian Schmid
 * Copyright (c) 2023, Lothar Maisenbacher
 *
 * All rights reserved.
 *
 * @brief Red Pitaya library PID module interface
 *
 * @Author Red Pitaya
 *
 * (c) Red Pitaya  http://www.redpitaya.com
 *
 * This part of code is written in C programming language.
 * Please visit http://en.wikipedia.org/wiki/C_(programming_language)
 * for more details on the language used herein.
 */



#ifndef __PID_H
#define __PID_H

#include <stdint.h>
#include <stdbool.h>
#include <redpitaya/lockbox.h>
#include "analog_mixed_signals.h"

#define SETPOINT_MAX        1.0     // V
#define DATA_BIT_LENGTH     14      // Used for V->counts conversion

// Base PID address
static const int PID_BASE_ADDR = 0x00300000;

// PID structure declaration. The registers of parameter set 2 (setpoint,
// gains, lock window, holdoff) sit at the addresses of set 1 + 0x100;
// pid_SetRegister addresses both sets.
typedef struct pid_control_s {
    uint32_t conf;
    uint32_t conf2;
    uint32_t reserved[2];
    uint32_t pid11_setpoint;
    uint32_t pid12_setpoint;
    uint32_t pid21_setpoint;
    uint32_t pid22_setpoint;
    uint32_t pid11_Kp;
    uint32_t pid12_Kp;
    uint32_t pid21_Kp;
    uint32_t pid22_Kp;
    uint32_t pid11_Ki;
    uint32_t pid12_Ki;
    uint32_t pid21_Ki;
    uint32_t pid22_Ki;
    uint32_t pid11_Kd;
    uint32_t pid12_Kd;
    uint32_t pid21_Kd;
    uint32_t pid22_Kd;
    uint32_t relock11_minval;
    uint32_t relock12_minval;
    uint32_t relock21_minval;
    uint32_t relock22_minval;
    uint32_t relock11_maxval;
    uint32_t relock12_maxval;
    uint32_t relock21_maxval;
    uint32_t relock22_maxval;
    uint32_t relock11_stepsize;
    uint32_t relock12_stepsize;
    uint32_t relock21_stepsize;
    uint32_t relock22_stepsize;
    uint32_t relock11_input;
    uint32_t relock12_input;
    uint32_t relock21_input;
    uint32_t relock22_input;
    uint32_t pid11_Kii;
    uint32_t pid12_Kii;
    uint32_t pid21_Kii;
    uint32_t pid22_Kii;
    uint32_t pid11_Kg;
    uint32_t pid12_Kg;
    uint32_t pid21_Kg;
    uint32_t pid22_Kg;
    uint32_t pid11_ext_reset_input;
    uint32_t pid12_ext_reset_input;
    uint32_t pid21_ext_reset_input;
    uint32_t pid22_ext_reset_input;
    uint32_t pset_ctrl[4];         // parameter set selection: [1:0] mode, [6:4] input
    uint32_t holdoff[4];           // holdoff after a switch into the set, in clock cycles
    uint32_t reserved2[4];
    uint32_t pset_status;          // read only, see PID_STATUS_*
    uint32_t reserved3[2];
    uint32_t feature_id;           // read only, PID_FEATURE_MAGIC in the upper half
    uint32_t set2[64];             // parameter set 2, at the offsets of set 1
    uint32_t counters[4][4];       // read only, event counters [PID_CNT_*][pid]
} pid_control_t;

#define PID_BASE_SIZE sizeof(pid_control_t)

// Byte offsets of the registers that exist once per parameter set, for the
// parameter set 1 and PID 11; + 4 per PID, + PID_SET_STRIDE for parameter set 2
static const uint32_t PID_SET_STRIDE = 0x100;
static const uint32_t PID_REG_SETPOINT = 0x10;
static const uint32_t PID_REG_KP = 0x20;
static const uint32_t PID_REG_KI = 0x30;
static const uint32_t PID_REG_KD = 0x40;
static const uint32_t PID_REG_RELOCK_MIN = 0x50;
static const uint32_t PID_REG_RELOCK_MAX = 0x60;
static const uint32_t PID_REG_KII = 0x90;
static const uint32_t PID_REG_KG = 0xA0;
static const uint32_t PID_REG_HOLDOFF = 0xD0;

// Gateware with the two parameter sets reads this in the upper half of feature_id
static const uint32_t PID_FEATURE_MAGIC = 0x5053;
// The version in the lower half of feature_id from which the event counters exist
static const uint32_t PID_FEATURE_COUNTERS = 2;
// counters: the first index
enum { PID_CNT_SWITCHES, PID_CNT_HOLDOFFS_LEFT, PID_CNT_HOLDOFFS_OUT, PID_CNT_UNLOCKS };
// pset_ctrl
static const uint32_t PID_PSET_MODE_MASK = 0x3;
static const uint32_t PID_PSET_INPUT_SHIFT = 4;
static const uint32_t PID_PSET_INPUT_MASK = 0x7;
// pset_status: bit (SHIFT + pid), the input levels at bit (SHIFT + input)
static const uint32_t PID_STATUS_ACTIVE_SHIFT = 0;
static const uint32_t PID_STATUS_HOLDOFF_SHIFT = 4;
static const uint32_t PID_STATUS_WINDOW_SHIFT = 8;
static const uint32_t PID_STATUS_VIOLATED_SHIFT = 12;
static const uint32_t PID_STATUS_LEVEL_SHIFT = 16;

static const uint32_t PID_CONF_MASK = 0xFFFFFFFF; // (32 bits)
static const uint32_t PID_CONF2_MASK = 0x0000000F; // (4 bits)
// Bit positions in `conf` of the per-PID flags, bit (SHIFT + pid) for
// pid = RP_PID_11..RP_PID_22: the integrator reset, the hold setting, the
// output enable and the lock status the FPGA derives from the relock input
// (read together by pid_GetLockHoldBits)
static const uint32_t PID_CONF_INT_RESET_SHIFT = 0;
static const uint32_t PID_CONF_HOLD_SHIFT = 12;
static const uint32_t PID_CONF_ENABLE_SHIFT = 20;
static const uint32_t PID_CONF_LOCKED_SHIFT = 24;
static const uint32_t PID_SETPOINT_MASK = 0x3FFF; // (14 bits)
static const uint32_t PID_KP_MASK = 0xFFFFFF; // (24 bits)
static const uint32_t PID_KI_MASK = 0xFFFFFF; // (24 bits)
static const uint32_t PID_KD_MASK = 0xFFFFFF; // (24 bits)
static const uint32_t PID_STEPSIZE_MASK = 0xFFFFFF; // (24 bits)
static const uint32_t PID_RELOCK_MASK = 0xFFF; // (12 bits)
static const uint32_t PID_RELOCK_INPUT_MASK = 0x3; // (2 bits)
static const uint32_t PID_KII_MASK = 0xFFFFFF; // (24 bits)
static const uint32_t PID_KG_MASK = 0xFFFFFF; // (24 bits)
static const uint32_t PID_EXT_RESET_INPUT_MASK = 0x3; // (2 bits)

static const float PID_TIMESTEP = 8E-9; // Inverse of the sampling rate
static const float PID_DACCOUNT = 1.221E-4; // DAC count in V = 2V/2**14
static const uint32_t PID_PSR = 12; // P gain = Kp >> PID_PSR
static const uint32_t PID_ISR = 28; // I gain = Ki >> PID_PSR
static const uint32_t PID_DSR = 8; // D gain = Kp >> PID_DSR
// Slew rate (in DAC counts/clock cycle) = stepsize >> PID_STEPSR
static const uint32_t PID_STEPSR = 18;

int pid_Init();
int pid_Release();

int pid_SetPIDSetpoint(rp_pid_t pid, float setpoint);
int pid_GetPIDSetpoint(rp_pid_t pid, float *setpoint);
int pid_SetPIDKp(rp_pid_t pid, float kp);
int pid_GetPIDKp(rp_pid_t pid, float *kp);
int pid_SetPIDKi(rp_pid_t pid, float ki);
int pid_GetPIDKi(rp_pid_t pid, float *ki);
int pid_SetPIDKd(rp_pid_t pid, float kd);
int pid_GetPIDKd(rp_pid_t pid, float *kd);
int pid_SetPIDKii(rp_pid_t pid, float kii);
int pid_GetPIDKii(rp_pid_t pid, float *kii);
int pid_SetPIDKg(rp_pid_t pid, float kg);
int pid_GetPIDKg(rp_pid_t pid, float *kg);
int pid_SetPIDIntReset(rp_pid_t pid, bool enable);
int pid_GetPIDIntReset(rp_pid_t pid, bool *enabled);
int pid_SetPIDInverted(rp_pid_t pid, bool inverted);
int pid_GetPIDInverted(rp_pid_t pid, bool *inverted);
int pid_SetResetWhenRailed(rp_pid_t pid, bool enable);
int pid_GetResetWhenRailed(rp_pid_t pid, bool *enabled);
int pid_SetHold(rp_pid_t pid, bool enable);
int pid_GetHold(rp_pid_t pid, bool *enabled);
int pid_SetPIDRelock(rp_pid_t pid, bool enable);
int pid_GetPIDRelock(rp_pid_t pid, bool *enabled);
int pid_SetPIDEnable(rp_pid_t pid, bool enable);
int pid_GetPIDEnable(rp_pid_t pid, bool *enabled);
int pid_GetPIDLockStatus(rp_pid_t pid, bool *lock_status);
int pid_GetLockHoldBits(uint8_t *locked, uint8_t *held);
int pid_SetLock(rp_pid_t pid, bool lock);
int pid_GetLock(rp_pid_t pid, bool *lock);
int pid_GetCounters(rp_pid_t pid, rp_pid_counters_t *counters);
int pid_GetUnlockCounts(uint32_t unlocks[4]);
int pid_SetRelockStepsize(rp_pid_t pid, float stepsize);
int pid_GetRelockStepsize(rp_pid_t pid, float *stepsize);
int pid_SetRelockMinimum(rp_pid_t pid, float minimum);
int pid_GetRelockMinimum(rp_pid_t pid, float *minimum);
int pid_SetRelockMaximum(rp_pid_t pid, float maximum);
int pid_GetRelockMaximum(rp_pid_t pid, float *maximum);
int pid_SetRelockInput(rp_pid_t pid, rp_apin_t pin);
int pid_GetRelockInput(rp_pid_t pid, rp_apin_t *pin);
int pid_SetLockStatusOutputEnable(rp_pid_t pid, bool enable);
int pid_GetLockStatusOutputEnable(rp_pid_t pid, bool *enabled);
int pid_SetExtResetEnable(rp_pid_t pid, bool enable);
int pid_GetExtResetEnable(rp_pid_t pid, bool *enabled);
int pid_SetExtResetInput(rp_pid_t pid, rp_dpin_t pin);
int pid_GetExtResetInput(rp_pid_t pid, rp_dpin_t *pin);

int pid_HasParamSets(bool *available);
int pid_SetParam(rp_pid_t pid, rp_pidset_t set, rp_pidparam_t param, float value);
int pid_GetParam(rp_pid_t pid, rp_pidset_t set, rp_pidparam_t param, float *value);
int pid_CopyParams(rp_pid_t pid, rp_pidset_t from, rp_pidset_t to);
int pid_SetParamSetMode(rp_pid_t pid, rp_pset_mode_t mode);
int pid_GetParamSetMode(rp_pid_t pid, rp_pset_mode_t *mode);
int pid_SetParamSetInput(rp_pid_t pid, rp_dpin_t pin);
int pid_GetParamSetInput(rp_pid_t pid, rp_dpin_t *pin);
int pid_GetParamSetState(rp_pid_t pid, rp_pidset_t *active, bool *holdoff, bool *level, bool *violated);

#endif //__PID_H
