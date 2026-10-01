/**
 * Copyright (c) 2026, Lothar Maisenbacher
 *
 * All rights reserved.
 *
 * @brief The lockbox settings file: reading, migration of older versions,
 * and writing.
 *
 * The file is the binary image of rp_lockbox_params_t. Version 3 appended
 * parameter set 2 and the set selection to version 2, so a version 2 image is
 * the beginning of a version 3 one.
 */

#include <errno.h>
#include <fcntl.h>
#include <libgen.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "config.h"

// Version 2 of the settings file (rp-lockbox 1.0 to 1.3), frozen
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
} rp_lockbox_params_v2_t;

_Static_assert(sizeof(rp_lockbox_params_v2_t) == 264,
               "the version 2 settings file is 264 bytes");
_Static_assert(offsetof(rp_lockbox_params_t, pid_setpoint_2) == sizeof(rp_lockbox_params_v2_t),
               "version 3 appends to version 2");

void cfg_DefaultSet2(rp_lockbox_params_t *params)
{
    memcpy(params->pid_setpoint_2, params->pid_setpoint, sizeof(params->pid_setpoint));
    memcpy(params->pid_kp_2, params->pid_kp, sizeof(params->pid_kp));
    memcpy(params->pid_ki_2, params->pid_ki, sizeof(params->pid_ki));
    memcpy(params->pid_kd_2, params->pid_kd, sizeof(params->pid_kd));
    memcpy(params->pid_kii_2, params->pid_kii, sizeof(params->pid_kii));
    memcpy(params->pid_kg_2, params->pid_kg, sizeof(params->pid_kg));
    memcpy(params->pid_relock_minimum_2, params->pid_relock_minimum, sizeof(params->pid_relock_minimum));
    memcpy(params->pid_relock_maximum_2, params->pid_relock_maximum, sizeof(params->pid_relock_maximum));
    for (int i = 0; i < 4; i++) {
        params->pid_holdoff[i] = 0;
        params->pid_holdoff_2[i] = 0;
        params->pid_pset_mode[i] = RP_PSET_MODE_1;
        params->pid_pset_input[i] = RP_DIO7_P;
    }
}

int cfg_Parse(const void *data, size_t size, rp_lockbox_params_t *params, int *version)
{
    int v;

    if (size < sizeof(v))
        return RP_EICV;
    memcpy(&v, data, sizeof(v));
    memset(params, 0, sizeof(*params));

    if (v == 2 && size == sizeof(rp_lockbox_params_v2_t)) {
        memcpy(params, data, size);
        cfg_DefaultSet2(params);
        params->config_version = LOCKBOX_CONFIG_VERSION;
    }
    else if (v == LOCKBOX_CONFIG_VERSION && size == sizeof(rp_lockbox_params_t)) {
        memcpy(params, data, size);
    }
    else
        return RP_EICV;

    *version = v;
    return RP_OK;
}

int cfg_Read(const char *path, rp_lockbox_params_t *params, int *version)
{
    // One byte more than the largest version, to see a longer file
    unsigned char image[sizeof(rp_lockbox_params_t) + 1];
    size_t size;
    FILE *file = fopen(path, "rb");

    if (file == NULL)
        return RP_EOCF;
    size = fread(image, 1, sizeof(image), file);
    fclose(file);
    return cfg_Parse(image, size, params, version);
}

// Write `size` bytes to a new file at `path`, through a temporary file
static int cfg_WriteFile(const char *path, const void *data, size_t size)
{
    char tmp[PATH_MAX];
    char dir[PATH_MAX];
    const unsigned char *bytes = data;
    size_t done = 0;
    int fd;

    if (snprintf(tmp, sizeof(tmp), "%s.XXXXXX", path) >= (int)sizeof(tmp))
        return RP_EOCF;
    fd = mkstemp(tmp);
    if (fd < 0)
        return RP_EOCF;
    // mkstemp creates the file for its owner only; the settings file is world-readable
    if (fchmod(fd, 0644) < 0)
        goto fail;
    while (done < size) {
        ssize_t n = write(fd, bytes + done, size - done);
        if (n < 0) {
            if (errno == EINTR)
                continue;
            goto fail;
        }
        done += (size_t)n;
    }
    if (fsync(fd) < 0)
        goto fail;
    if (close(fd) < 0) {
        fd = -1;
        goto fail;
    }
    fd = -1;
    if (rename(tmp, path) < 0)
        goto fail;

    // The rename itself reaches the disk with the directory
    snprintf(dir, sizeof(dir), "%s", path);
    fd = open(dirname(dir), O_RDONLY);
    if (fd >= 0) {
        fsync(fd);
        close(fd);
    }
    return RP_OK;

fail:
    if (fd >= 0)
        close(fd);
    unlink(tmp);
    return RP_EOCF;
}

int cfg_Write(const char *path, const rp_lockbox_params_t *params)
{
    return cfg_WriteFile(path, params, sizeof(*params));
}

int cfg_KeepCopy(const char *path, const char *suffix)
{
    char copy[PATH_MAX];
    unsigned char image[4096];
    size_t size;
    FILE *file;

    if (snprintf(copy, sizeof(copy), "%s%s", path, suffix) >= (int)sizeof(copy))
        return RP_EOCF;
    if (access(copy, F_OK) == 0)
        return RP_OK;

    file = fopen(path, "rb");
    if (file == NULL)
        return RP_EOCF;
    size = fread(image, 1, sizeof(image), file);
    fclose(file);
    return cfg_WriteFile(copy, image, size);
}
