/**
 * Copyright (c) 2026, Lothar Maisenbacher
 *
 * All rights reserved.
 *
 * @brief The lockbox settings file (rp_SaveLockboxConfig, rp_LoadLockboxConfig):
 * reading, migration of older versions, and writing. No hardware access, so
 * it builds and tests on any host (api/test).
 */

#ifndef __CONFIG_H
#define __CONFIG_H

#include <stddef.h>
#include <redpitaya/lockbox.h>

/**
 * Fill the version 3 fields of parameter set 2 and the set selection with
 * what keeps a PID as it was before parameter sets existed: set 2 a copy of
 * set 1, no holdoff, always set 1.
 */
void cfg_DefaultSet2(rp_lockbox_params_t *params);

/**
 * Parse a settings file image of version 2 or 3 into the current version.
 * @param version Pointer where the version of the image is returned.
 * @return RP_OK, or RP_EICV for an unknown version or a size that does not
 * match its version.
 */
int cfg_Parse(const void *data, size_t size, rp_lockbox_params_t *params, int *version);

/**
 * Read and parse a settings file.
 * @return RP_OK, RP_EOCF if it cannot be opened, or an error of cfg_Parse.
 */
int cfg_Read(const char *path, rp_lockbox_params_t *params, int *version);

/**
 * Write a settings file: a temporary file in the same directory, flushed to
 * the disk, then renamed over the file, so a crash or a second writer never
 * leaves a partial file.
 * @return RP_OK or RP_EOCF.
 */
int cfg_Write(const char *path, const rp_lockbox_params_t *params);

/**
 * Copy a file to `path` + `suffix` unless that already exists.
 * @return RP_OK (also when the copy exists already) or RP_EOCF.
 */
int cfg_KeepCopy(const char *path, const char *suffix);

#endif //__CONFIG_H
