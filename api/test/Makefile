# Host tests of the API library's parts without hardware access (any Linux
# with gcc; no Red Pitaya):
#
#   make test     the settings file: migration, round trip, refused sizes;
#                 the PID register access against a register block in memory;
#                 saving and loading the settings through the whole library

CC ?= gcc
CFLAGS ?= -g -std=gnu99 -Wall -Werror -O2
INC = -I../include -I../src

all: test_config test_pid test_lockbox

test_config: test_config.c ../src/config.c
	$(CC) $(CFLAGS) $(INC) -o $@ $^

# cmn_Map is wrapped to map the register block of the test
test_pid: test_pid.c ../src/pid.c ../src/common.c
	$(CC) $(CFLAGS) $(INC) -o $@ $^ -lm -Wl,--wrap=cmn_Map,--wrap=cmn_Unmap

# The whole library, with the memory devices and the calibration EEPROM
# wrapped, and the settings file in /tmp; optimized as the library is
# (-Os), since -O2 finds maybe-uninitialized warnings in the upstream code
LIB_SRC = $(wildcard ../src/*.c) ../src/kiss_fft/kiss_fft.c ../src/kiss_fft/kiss_fftr.c
LIB_CFLAGS = -g -std=gnu99 -Wall -Werror -Os
WRAPPED = cmn_Init cmn_Map cmn_Unmap open mmap calib_Init calib_GetParams
comma = ,
empty =
space = $(empty) $(empty)

build_info.h:
	printf '#define BUILD_VERSION_STR "test"\n#define BUILD_REVISION_STR "test"\n' > $@

test_lockbox: test_lockbox.c $(LIB_SRC) build_info.h
	$(CC) $(LIB_CFLAGS) -U_FORTIFY_SOURCE $(INC) -I. -I../src/kiss_fft \
		-DCONFIG_FILE_PATH='"/tmp/rp-lockbox-test-pid_settings.conf"' \
		-o $@ test_lockbox.c $(LIB_SRC) -lm -lrt \
		-Wl,$(subst $(space),$(comma),$(addprefix --wrap=,$(WRAPPED)))

test: all
	./test_config
	./test_pid
	./test_lockbox

clean:
	rm -f test_config test_pid test_lockbox build_info.h

.PHONY: all test clean
