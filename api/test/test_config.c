/**
 * Copyright (c) 2026, Lothar Maisenbacher
 *
 * All rights reserved.
 *
 * Host tests of the settings file (api/src/config.c): a version 2 file loads
 * with parameter set 2 a copy of set 1, version 3 round-trips,
 * sizes that do not match their version are refused, and the copy of the
 * version 2 file is made once.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "config.h"

static int failures = 0;
static int checks = 0;

#define CHECK(cond, msg) do { \
    checks++; \
    if (!(cond)) { failures++; printf("  FAIL: %s (line %d)\n", msg, __LINE__); } \
} while (0)

// The version 2 layout, as the 1.3 software wrote it
typedef struct {
    int config_version;
    float pid_setpoint[4];
    float pid_kp[4];
    float pid_ki[4];
    float pid_kd[4];
    float pid_kii[4];
    float pid_kg[4];
    bool pid_int_reset[4];
    bool pid_inverted[4];
    bool pid_reset_when_railed[4];
    bool pid_hold[4];
    bool pid_relock_enabled[4];
    bool pid_enabled[4];
    float pid_relock_stepsize[4];
    float pid_relock_minimum[4];
    float pid_relock_maximum[4];
    rp_apin_t pid_relock_input[4];
    bool pid_lso_enabled[4];
    bool pid_ext_reset_enabled[4];
    rp_dpin_t pid_ext_reset_input[4];
    float limit_min[2];
    float limit_max[2];
    bool gen_enabled[2];
    bool gen_poffset_enabled[2];
    float gen_amp[2];
    float gen_offset[2];
    float gen_freq[2];
    rp_waveform_t gen_waveform[2];
} v2_t;

static void write_bytes(const char *path, const void *data, size_t size)
{
    FILE *f = fopen(path, "wb");
    fwrite(data, 1, size, f);
    fclose(f);
}

static void fill_v2(v2_t *v2)
{
    memset(v2, 0, sizeof(*v2));
    v2->config_version = 2;
    for (int i = 0; i < 4; i++) {
        v2->pid_setpoint[i] = 0.01f * (i + 1);
        v2->pid_kp[i] = 0.5f + i;
        v2->pid_ki[i] = 1000.0f * (i + 1);
        v2->pid_kd[i] = 1e-7f * (i + 1);
        v2->pid_kii[i] = 10.0f * (i + 1);
        v2->pid_kg[i] = 0.88f + i;
        v2->pid_inverted[i] = (i % 2) == 1;
        v2->pid_relock_enabled[i] = true;
        v2->pid_enabled[i] = i < 2;
        v2->pid_relock_stepsize[i] = 100.0f;
        v2->pid_relock_minimum[i] = 0.2f + i;
        v2->pid_relock_maximum[i] = 1.5f + i;
        v2->pid_relock_input[i] = RP_AIN0 + i;
        v2->pid_lso_enabled[i] = true;
        v2->pid_ext_reset_input[i] = RP_DIO5_P;
    }
    v2->limit_min[0] = -1.0f;
    v2->limit_max[0] = 1.0f;
    v2->gen_waveform[1] = RP_WAVEFORM_SQUARE;
}

int main(void)
{
    char dir[] = "/tmp/rp-lockbox-config-test-XXXXXX";
    char path[512];
    char copy[520];
    v2_t v2;
    rp_lockbox_params_t p;
    rp_lockbox_params_t q;
    int version = -1;
    unsigned char big[sizeof(rp_lockbox_params_t) + 8];

    if (mkdtemp(dir) == NULL) {
        perror("mkdtemp");
        return 2;
    }
    snprintf(path, sizeof(path), "%s/pid_settings.conf", dir);
    snprintf(copy, sizeof(copy), "%s.v2", path);
    printf("test_config (%s)\n", path);

    CHECK(sizeof(v2_t) == 264, "version 2 is 264 bytes");

    // A version 2 file loads into version 3
    fill_v2(&v2);
    write_bytes(path, &v2, sizeof(v2));
    CHECK(cfg_Read(path, &p, &version) == RP_OK, "version 2 file reads");
    CHECK(version == 2, "version 2 reported");
    CHECK(p.config_version == LOCKBOX_CONFIG_VERSION, "upgraded to the current version");
    CHECK(memcmp(&p.pid_setpoint, &v2.pid_setpoint, sizeof(v2) - sizeof(int)) == 0,
          "version 2 fields unchanged");
    for (int i = 0; i < 4; i++) {
        CHECK(p.pid_setpoint_2[i] == v2.pid_setpoint[i], "set 2 setpoint = set 1");
        CHECK(p.pid_kp_2[i] == v2.pid_kp[i], "set 2 KP = set 1");
        CHECK(p.pid_ki_2[i] == v2.pid_ki[i], "set 2 KI = set 1");
        CHECK(p.pid_kd_2[i] == v2.pid_kd[i], "set 2 KD = set 1");
        CHECK(p.pid_kii_2[i] == v2.pid_kii[i], "set 2 KII = set 1");
        CHECK(p.pid_kg_2[i] == v2.pid_kg[i], "set 2 KG = set 1");
        CHECK(p.pid_relock_minimum_2[i] == v2.pid_relock_minimum[i], "set 2 window min = set 1");
        CHECK(p.pid_relock_maximum_2[i] == v2.pid_relock_maximum[i], "set 2 window max = set 1");
        CHECK(p.pid_holdoff[i] == 0 && p.pid_holdoff_2[i] == 0, "no holdoff");
        CHECK(p.pid_pset_mode[i] == RP_PSET_MODE_1, "always set 1");
        CHECK(p.pid_pset_input[i] == RP_DIO7_P, "input DIO7_P");
    }

    // The version 2 copy is made once and never overwritten
    CHECK(access(copy, F_OK) != 0, "no copy before");
    CHECK(cfg_KeepCopy(path, ".v2") == RP_OK, "copy made");
    CHECK(cfg_Read(copy, &q, &version) == RP_OK && version == 2, "the copy is the version 2 file");

    // Version 3 round-trips through cfg_Write
    p.pid_kp_2[2] = 0.125f;
    p.pid_holdoff_2[1] = 1e-3f;
    p.pid_pset_mode[0] = RP_PSET_MODE_HIGH_2;
    p.pid_pset_input[0] = RP_DIO5_N;
    CHECK(cfg_Write(path, &p) == RP_OK, "version 3 written");
    CHECK(cfg_Read(path, &q, &version) == RP_OK, "version 3 reads");
    CHECK(version == LOCKBOX_CONFIG_VERSION, "version 3 reported");
    CHECK(memcmp(&p, &q, sizeof(p)) == 0, "version 3 round trip");
    CHECK(cfg_KeepCopy(path, ".v2") == RP_OK, "second copy call");
    CHECK(cfg_Read(copy, &q, &version) == RP_OK && version == 2, "the copy still holds version 2");

    // Refused: sizes that do not match their version, unknown versions, empty files
    write_bytes(path, &v2, sizeof(v2) - 1);
    CHECK(cfg_Read(path, &q, &version) == RP_EICV, "truncated version 2 refused");
    write_bytes(path, &p, sizeof(p) - 4);
    CHECK(cfg_Read(path, &q, &version) == RP_EICV, "truncated version 3 refused");
    memset(big, 0, sizeof(big));
    memcpy(big, &p, sizeof(p));
    write_bytes(path, big, sizeof(big));
    CHECK(cfg_Read(path, &q, &version) == RP_EICV, "longer version 3 refused");
    v2.config_version = 1;
    write_bytes(path, &v2, sizeof(v2));
    CHECK(cfg_Read(path, &q, &version) == RP_EICV, "version 1 refused");
    write_bytes(path, &v2, 0);
    CHECK(cfg_Read(path, &q, &version) == RP_EICV, "empty file refused");
    unlink(path);
    CHECK(cfg_Read(path, &q, &version) == RP_EOCF, "missing file");

    unlink(copy);
    rmdir(dir);

    if (failures == 0)
        printf("PASS (%d checks)\n", checks);
    else
        printf("FAIL (%d of %d checks failed)\n", failures, checks);
    return failures != 0;
}
