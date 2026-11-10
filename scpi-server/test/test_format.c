/**
 * Copyright (c) 2026, Lothar Maisenbacher
 *
 * All rights reserved.
 *
 * Host test of the number formats of the SCPI replies (src/format.c): a time
 * in seconds goes out to the microsecond whatever its size, so a logger's
 * difference of two of the lockbox monitor's totals keeps its fraction.
 * libscpi's own double format is checked beside it, as the reason.
 */

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "scpi/utils.h"
#include "format.h"

static int failures = 0;
static int checks = 0;

static void expect_text(double seconds, const char *text)
{
    char str[32];
    size_t len = RP_FormatSeconds(seconds, str, sizeof(str));

    checks++;
    if (strcmp(str, text) != 0 || len != strlen(text)) {
        failures++;
        printf("  FAIL: %.9f -> \"%s\" (length %zu), expected \"%s\"\n", seconds, str, len, text);
    }
}

/* The text of `seconds`, read back as a client reads it */
static double round_trip(double seconds)
{
    char str[32];
    RP_FormatSeconds(seconds, str, sizeof(str));
    return strtod(str, NULL);
}

static void expect_near(const char *what, double got, double expected, double tolerance)
{
    checks++;
    if (!(fabs(got - expected) <= tolerance)) {
        failures++;
        printf("  FAIL: %s = %.9f, expected %.9f +- %g\n", what, got, expected, tolerance);
    }
}

int main(void)
{
    printf("test_format\n");

    // Fixed point to the microsecond, trailing zeros dropped
    expect_text(547000.123456, "547000.123456");
    expect_text(123456.789, "123456.789");
    expect_text(4321.2, "4321.2");
    expect_text(0.0005, "0.0005");
    expect_text(0.000999, "0.000999");
    expect_text(1.0, "1");
    expect_text(0.0, "0");
    expect_text(-1.0, "-1");
    expect_text(1e-7, "0");
    expect_text(-1e-7, "0");
    expect_text(0.0000005001, "0.000001");
    // Beyond fixed point's range: 17 significant digits
    expect_text(1e12, "1000000000000");
    expect_text(12345678901234.5, "12345678901234.5");

    // libscpi's double format keeps six significant digits: a monitor total
    // above 1e5 s loses its fraction, which is why the times do not use it
    {
        char str[32];
        SCPI_DoubleToStr(123456.789, str, sizeof(str));
        checks++;
        if (strcmp(str, "123457") != 0) {
            failures++;
            printf("  FAIL: SCPI_DoubleToStr(123456.789) = \"%s\", expected \"123457\"\n", str);
        }
    }

    // A logger's difference of two totals one poll apart keeps its fraction,
    // at any total up to 1e9 s
    {
        const double totals[] = {0.0, 99.9, 999.99, 12345.6, 123456.789, 547000.1, 999999.9,
                                 12345678.9, 999999999.0};
        for (size_t i = 0; i < sizeof(totals) / sizeof(totals[0]); i++) {
            char what[80];
            snprintf(what, sizeof(what), "the difference of %.1f s and 0.017 s more", totals[i]);
            expect_near(what, round_trip(totals[i] + 0.017) - round_trip(totals[i]), 0.017, 1.01e-6);
        }
    }

    // The monitor's nanosecond totals arrive to within half a microsecond
    {
        const uint64_t ns[] = {1ULL, 999999ULL, 1000000ULL, 547000123456789ULL,
                               999999999999999ULL};
        for (size_t i = 0; i < sizeof(ns) / sizeof(ns[0]); i++) {
            char what[80];
            double seconds = (double)ns[i] / 1e9;
            snprintf(what, sizeof(what), "%llu ns read back", (unsigned long long)ns[i]);
            expect_near(what, round_trip(seconds), seconds, 0.5e-6 + 1e-9);
        }
    }

    // The text always fits the buffer the SCPI server gives it
    {
        const double values[] = {1e12 - 1e-6, -1e12 + 1e-6, 1e300, -1e300, NAN, INFINITY,
                                 -INFINITY, 1.8446744073709552e10};
        for (size_t i = 0; i < sizeof(values) / sizeof(values[0]); i++) {
            char str[32];
            size_t len = RP_FormatSeconds(values[i], str, sizeof(str));
            checks++;
            if (len >= sizeof(str)) {
                failures++;
                printf("  FAIL: %g needs %zu characters\n", values[i], len);
            }
        }
    }

    if (failures == 0)
        printf("PASS (%d checks)\n", checks);
    else
        printf("FAIL (%d of %d checks failed)\n", failures, checks);
    return failures != 0;
}
