/**
 * Copyright (c) 2026, Lothar Maisenbacher
 *
 * All rights reserved.
 *
 * Host test of saving and loading the lockbox settings
 * (rp_SaveLockboxConfig, rp_LoadLockboxConfig) through the whole library,
 * against register blocks in memory: every setting written through the API,
 * saved, the registers cleared and the file loaded gives the same register
 * contents, bit for bit. Also: an FPGA image without the parameter sets
 * keeps parameter set 2 and the set selection of the file when it saves, and
 * a version 2 file loads with set 2 a copy of set 1.
 *
 * The memory devices are replaced: cmn_Init and cmn_Map (most blocks), open
 * and mmap of /dev/mem (the output limiter), and the calibration EEPROM.
 */

#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "redpitaya/lockbox.h"
#include "common.h"
#include "pid.h"

static int failures = 0;
static int checks = 0;

#define CHECK(cond, msg) do { \
    checks++; \
    if (!(cond)) { failures++; printf("  FAIL: %s (line %d)\n", msg, __LINE__); } \
} while (0)

// The register blocks, one per base address
#define MAX_REGIONS 16
static struct {
    size_t offset;
    size_t size;
    uint8_t *mem;
    uint8_t *snapshot;
} regions[MAX_REGIONS];
static int n_regions = 0;

static uint8_t *region(size_t offset, size_t size)
{
    for (int i = 0; i < n_regions; i++)
        if (regions[i].offset == offset)
            return regions[i].mem;
    regions[n_regions].offset = offset;
    regions[n_regions].size = size;
    regions[n_regions].mem = calloc(1, size);
    regions[n_regions].snapshot = calloc(1, size);
    return regions[n_regions++].mem;
}

static uint32_t *pid_block(void)
{
    return (uint32_t *)region(PID_BASE_ADDR, PID_BASE_SIZE);
}

// An FPGA image with or without the parameter sets
static void set_feature(bool sets)
{
    pid_block()[0xFC / 4] = sets ? 0x50530002 : 0;
}

int __wrap_cmn_Init(void)
{
    return RP_OK;
}

int __wrap_cmn_Map(size_t size, size_t offset, void **mapped)
{
    *mapped = region(offset, size);
    return RP_OK;
}

int __wrap_cmn_Unmap(size_t size, void **mapped)
{
    (void)size;
    *mapped = NULL;
    return RP_OK;
}

#define FAKE_MEM_FD 1000

int __real_open(const char *path, int flags, ...);
int __wrap_open(const char *path, int flags, ...)
{
    mode_t mode = 0;
    if (strcmp(path, "/dev/mem") == 0)
        return FAKE_MEM_FD;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = va_arg(args, int);
        va_end(args);
    }
    return __real_open(path, flags, mode);
}

void *__real_mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset);
void *__wrap_mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset)
{
    if (fd == FAKE_MEM_FD)
        return region((size_t)offset, length);
    return __real_mmap(addr, length, prot, flags, fd, offset);
}

// A board with a typical calibration: 1 V full scale, small offsets
int __wrap_calib_Init(void)
{
    return RP_OK;
}

rp_calib_params_t __wrap_calib_GetParams(void)
{
    rp_calib_params_t calib;
    memset(&calib, 0, sizeof(calib));
    calib.fe_ch1_fs_g_hi = cmn_CalibFullScaleFromVoltage(1);
    calib.fe_ch2_fs_g_hi = cmn_CalibFullScaleFromVoltage(1);
    calib.fe_ch1_fs_g_lo = cmn_CalibFullScaleFromVoltage(20);
    calib.fe_ch2_fs_g_lo = cmn_CalibFullScaleFromVoltage(20);
    calib.be_ch1_fs = cmn_CalibFullScaleFromVoltage(1);
    calib.be_ch2_fs = cmn_CalibFullScaleFromVoltage(1);
    calib.be_ch1_dc_offs = 37;
    calib.be_ch2_dc_offs = -21;
    calib.fe_ch1_hi_offs = 15;
    calib.fe_ch2_hi_offs = -8;
    return calib;
}

static void snapshot(void)
{
    for (int i = 0; i < n_regions; i++)
        memcpy(regions[i].snapshot, regions[i].mem, regions[i].size);
}

static void clear_registers(void)
{
    for (int i = 0; i < n_regions; i++)
        memset(regions[i].mem, 0, regions[i].size);
}

// Compare every register block with its snapshot; print what differs
static int registers_differ(void)
{
    int differ = 0;
    for (int i = 0; i < n_regions; i++) {
        uint32_t *now = (uint32_t *)regions[i].mem;
        uint32_t *then = (uint32_t *)regions[i].snapshot;
        for (size_t w = 0; w < regions[i].size / 4; w++) {
            if (now[w] != then[w]) {
                if (differ < 20)
                    printf("    block 0x%06zx + 0x%04zx: 0x%08x before, 0x%08x after\n",
                           regions[i].offset, 4 * w, then[w], now[w]);
                differ++;
            }
        }
    }
    return differ;
}

// Every setting of the file, through the API, with values as typed on the web interface
static void write_settings(void)
{
    const rp_apin_t relock_inputs[4] = {RP_AIN0, RP_AIN3, RP_AIN1, RP_AIN2};
    const rp_dpin_t reset_inputs[4] = {RP_DIO5_P, RP_DIO6_P, RP_DIO7_P, RP_DIO0_N};
    const rp_dpin_t set_inputs[4] = {RP_DIO7_N, RP_DIO5_P, RP_DIO0_N, RP_DIO6_N};
    const rp_pset_mode_t modes[4] = {RP_PSET_MODE_HIGH_1, RP_PSET_MODE_2, RP_PSET_MODE_HIGH_2,
                                     RP_PSET_MODE_1};

    for (int i = 0; i < 4; i++) {
        rp_PIDSetSetpoint(i, 0.123f - 0.05f * i);
        rp_PIDSetKp(i, 0.37f + 0.11f * i);
        rp_PIDSetKi(i, 1234.5f + 100.0f * i);
        rp_PIDSetKd(i, 3.3e-7f * (i + 1));
        rp_PIDSetKii(i, 12.5f * (i + 1));
        rp_PIDSetKg(i, 0.85f + 0.1f * i);
        rp_PIDSetIntReset(i, i == 1);
        rp_PIDSetInverted(i, i == 2);
        rp_PIDSetResetWhenRailed(i, i != 3);
        rp_PIDSetHold(i, i == 3);
        rp_PIDSetRelock(i, i != 1);
        rp_PIDSetEnable(i, i != 2);
        rp_PIDSetRelockStepsize(i, 523.0f * (i + 1));
        rp_PIDSetRelockMinimum(i, 0.55f + 0.1f * i);
        rp_PIDSetRelockMaximum(i, 2.75f - 0.1f * i);
        rp_PIDSetRelockInput(i, relock_inputs[i]);
        rp_PIDSetLockStatusOutputEnable(i, i % 2 == 0);
        rp_PIDSetExtResetEnable(i, i == 0);
        rp_PIDSetExtResetInput(i, reset_inputs[i]);

        rp_PIDSetParam(i, RP_PSET_2, RP_PID_SETPOINT, -0.211f + 0.07f * i);
        rp_PIDSetParam(i, RP_PSET_2, RP_PID_KP, 0.19f + 0.03f * i);
        rp_PIDSetParam(i, RP_PSET_2, RP_PID_KI, 777.7f * (i + 1));
        rp_PIDSetParam(i, RP_PSET_2, RP_PID_KD, 1.7e-7f * (i + 1));
        rp_PIDSetParam(i, RP_PSET_2, RP_PID_KII, 3.3f * (i + 1));
        rp_PIDSetParam(i, RP_PSET_2, RP_PID_KG, 1.72f - 0.2f * i);
        rp_PIDSetParam(i, RP_PSET_2, RP_PID_RELOCK_MIN, 0.31f + 0.2f * i);
        rp_PIDSetParam(i, RP_PSET_2, RP_PID_RELOCK_MAX, 3.1f - 0.2f * i);
        rp_PIDSetParam(i, RP_PSET_1, RP_PID_HOLDOFF, 1.5e-3f * (i + 1));
        rp_PIDSetParam(i, RP_PSET_2, RP_PID_HOLDOFF, 2.25e-5f * (i + 1));
        rp_PIDSetParamSetInput(i, set_inputs[i]);
        rp_PIDSetParamSetMode(i, modes[i]);
    }
    rp_LimitMin(RP_CH_1, -0.8f);
    rp_LimitMax(RP_CH_1, 0.9f);
    rp_LimitMin(RP_CH_2, -0.45f);
    rp_LimitMax(RP_CH_2, 0.6f);
    rp_GenWaveform(RP_CH_1, RP_WAVEFORM_SINE);
    rp_GenWaveform(RP_CH_2, RP_WAVEFORM_TRIANGLE);
    rp_GenAmp(RP_CH_1, 0.4f);
    rp_GenAmp(RP_CH_2, 0.25f);
    rp_GenOffset(RP_CH_1, 0.1f);
    rp_GenOffset(RP_CH_2, -0.2f);
    rp_GenFreq(RP_CH_1, 1234.5f);
    rp_GenFreq(RP_CH_2, 10.0f);
    rp_GenOutEnable(RP_CH_1);
    rp_GenOutDisable(RP_CH_2);
    rp_GenPOffsetDisable(RP_CH_1);
    rp_GenPOffsetEnable(RP_CH_2);
}

static const char *settings_path(const char *suffix)
{
    static char path[256];
    snprintf(path, sizeof(path), "%s%s", CONFIG_FILE_PATH, suffix);
    return path;
}

int main(void)
{
    uint32_t set2_regs[64];
    uint32_t *pid;
    float value;
    rp_lockbox_params_t file;
    FILE *f;
    int differ;

    printf("test_lockbox (%s)\n", CONFIG_FILE_PATH);
    unlink(settings_path(""));
    unlink(settings_path(".v2"));

    set_feature(true);
    CHECK(rp_Attach() == RP_OK, "attach");
    pid = pid_block();

    // Save, clear the registers, load: the registers come back bit for bit
    write_settings();
    snapshot();
    CHECK(rp_SaveLockboxConfig() == RP_OK, "save");
    clear_registers();
    set_feature(true);
    CHECK(rp_LoadLockboxConfig() == RP_OK, "load");
    differ = registers_differ();
    CHECK(differ == 0, "every register restored");
    CHECK((pid[0xC0 / 4] & 0x3) == 3 && ((pid[0xC0 / 4] >> 4) & 0x7) == 6, "PID 11: input high selects set 1, DIO7_N");
    CHECK((pid[0xC4 / 4] & 0x3) == 1, "PID 12: always set 2");
    CHECK((pid[0xC8 / 4] & 0x3) == 2, "PID 21: input high selects set 2");

    // Saved and loaded again: the file is stable
    CHECK(rp_SaveLockboxConfig() == RP_OK, "save again");
    clear_registers();
    set_feature(true);
    CHECK(rp_LoadLockboxConfig() == RP_OK, "load again");
    CHECK(registers_differ() == 0, "every register restored a second time");

    // An FPGA image without the parameter sets saves set 1 and keeps the rest
    // of the file
    memcpy(set2_regs, &pid[0x100 / 4], sizeof(set2_regs));
    set_feature(false);
    rp_Attach();
    rp_PIDSetKp(RP_PID_12, 0.5f);
    CHECK(rp_SaveLockboxConfig() == RP_OK, "save without the parameter sets");
    clear_registers();
    set_feature(true);
    rp_Attach();
    CHECK(rp_LoadLockboxConfig() == RP_OK, "load with the parameter sets");
    CHECK(memcmp(set2_regs, &pid[0x100 / 4], sizeof(set2_regs)) == 0, "set 2 and its holdoffs kept from the file");
    CHECK((pid[0xC0 / 4] & 0x3) == 3 && (pid[0xC4 / 4] & 0x3) == 1, "set selection kept from the file");
    CHECK(pid[0xD0 / 4] != 0, "set 1 holdoff kept from the file");
    rp_PIDGetKp(RP_PID_12, &value);
    CHECK(value == 0.5f, "set 1 as the old image had it");

    // A version 2 file: set 2 a copy of set 1, no holdoff, always set 1
    f = fopen(settings_path(""), "rb");
    CHECK(f != NULL && fread(&file, sizeof(file), 1, f) == 1, "read the file");
    if (f)
        fclose(f);
    file.config_version = 2;
    f = fopen(settings_path(""), "wb");
    CHECK(f != NULL && fwrite(&file, 264, 1, f) == 1, "write a version 2 file");
    if (f)
        fclose(f);
    clear_registers();
    set_feature(true);
    CHECK(rp_LoadLockboxConfig() == RP_OK, "load the version 2 file");
    for (int o = 0x10; o <= 0xA0; o += 0x10) {
        if (o == 0x70 || o == 0x80)
            continue;  // stepsize and relock input: shared, not per set
        for (int i = 0; i < 4; i++)
            CHECK(pid[(o + 0x100) / 4 + i] == pid[o / 4 + i], "set 2 register = set 1");
    }
    for (int i = 0; i < 4; i++) {
        CHECK(pid[0xD0 / 4 + i] == 0 && pid[0x1D0 / 4 + i] == 0, "no holdoff");
        CHECK(pid[0xC0 / 4 + i] == (2 << 4), "always set 1, input DIO7_P");
    }
    CHECK(access(settings_path(".v2"), F_OK) == 0, "the version 2 file kept");

    unlink(settings_path(""));
    unlink(settings_path(".v2"));

    if (failures == 0)
        printf("PASS (%d checks)\n", checks);
    else
        printf("FAIL (%d of %d checks failed)\n", failures, checks);
    return failures != 0;
}
