/**
 * $Id: $
 *
 * @brief Red Pitaya Scpi server utils module interface
 *
 * @Author Red Pitaya
 *
 * (c) Red Pitaya  http://www.redpitaya.com
 *
 * This part of code is written in C programming language.
 * Please visit http://en.wikipedia.org/wiki/C_(programming_language)
 * for more details on the language used herein.
 */

#ifndef COMMON_H_
#define COMMON_H_

#include <syslog.h>

#include "scpi/parser.h"
#include "redpitaya/lockbox.h"

#define CH_NUM		4

#define SCPI_CMD_NUM 	1

/* Every build logs to syslog: errors and connection events at their own
 * levels, the per-command trace at LOG_DEBUG. The log mask set in
 * scpi-server.c hides the trace unless the server was built with
 * SCPI_DEBUG (see the Makefile). */
#define RP_LOG(...) syslog(__VA_ARGS__)

int RP_ParseChArgv(scpi_t *context, rp_channel_t *channel);

#endif /* COMMON_H_ */
