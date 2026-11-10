/**
 * Copyright (c) 2026, Lothar Maisenbacher
 *
 * All rights reserved.
 *
 * @brief Number formats of the SCPI replies (see format.h).
 */

#include <math.h>
#include <stdio.h>
#include <string.h>

#include "format.h"

size_t RP_FormatSeconds(double seconds, char *str, size_t len)
{
    if (!isfinite(seconds) || fabs(seconds) >= 1e12)
        return (size_t)snprintf(str, len, "%.17g", seconds);

    int n = snprintf(str, len, "%.*f", RP_SECONDS_DECIMALS, seconds);
    if (n < 0 || (size_t)n >= len)
        return (size_t)n;
    /* Fixed point always has the point: drop the zeros behind it */
    while (n > 0 && str[n - 1] == '0')
        n--;
    if (n > 0 && str[n - 1] == '.')
        n--;
    str[n] = '\0';
    /* A negative value that rounds to zero is zero */
    if (strcmp(str, "-0") == 0) {
        str[0] = '0';
        str[1] = '\0';
        n = 1;
    }
    return (size_t)n;
}
