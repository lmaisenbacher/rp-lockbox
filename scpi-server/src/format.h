/**
 * Copyright (c) 2026, Lothar Maisenbacher
 *
 * All rights reserved.
 *
 * @brief Number formats of the SCPI replies that libscpi's own cannot
 * carry, without any libscpi dependency (tested on any host, see
 * test/test_format.c).
 *
 * libscpi writes a double with six significant digits ("%lg"). The lockbox
 * monitor's totals and ages grow without bound: a total of 123456.789 s
 * would go out as "123457", and the difference a logger takes between two
 * polls would be a whole second or nothing. Times in seconds therefore go
 * out in fixed point to the microsecond.
 */

#ifndef __FORMAT_H
#define __FORMAT_H

#include <stddef.h>

/** Decimals of a time in seconds: the microsecond */
#define RP_SECONDS_DECIMALS 6

/**
 * Writes `seconds` to `str` (at most `len` bytes with the terminating NUL)
 * in fixed point to the microsecond, trailing zeros and a trailing point
 * dropped ("547000.123456", "4321.2", "-1", "0"). A value of 1e12 s or more,
 * or not finite, goes out with 17 significant digits.
 * @return The length of the text, as snprintf's: `len` or more means it
 * was cut.
 */
size_t RP_FormatSeconds(double seconds, char *str, size_t len);

#endif /* __FORMAT_H */
