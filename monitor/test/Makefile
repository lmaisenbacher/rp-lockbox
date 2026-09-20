# Host build of the lockbox monitor's tests (any Linux with gcc; no Red Pitaya):
#
#   make test     unit tests of the lock-drop state machine, then the daemon
#                 end to end against the stub liblockbox (run_host_test.sh)
#
# `readmon` also builds on the Red Pitaya (make readmon) as an inspection
# tool for the running monitor.

CC ?= gcc
CFLAGS ?= -g -std=gnu99 -Wall -Werror -O2
INC = -I../../api/include -I../../api/src -I../src

API_SRC = ../../api/src
MON_SRC = ../src

all: test_lockstat lockbox-monitor-host readmon

test_lockstat: test_lockstat.c $(MON_SRC)/lockstat.c
	$(CC) $(CFLAGS) $(INC) -o $@ $^

# The daemon itself, linked against the stub instead of liblockbox
lockbox-monitor-host: $(MON_SRC)/lockbox-monitor.c $(MON_SRC)/lockstat.c stub_lockbox.c
	$(CC) $(CFLAGS) $(INC) -o $@ $^ -lpthread -lrt -lm

# The library's reader, as the SCPI server and the web interface use it
readmon: readmon.c $(API_SRC)/monitor.c
	$(CC) $(CFLAGS) $(INC) -o $@ $^ -lrt

test: all
	./test_lockstat
	bash ./run_host_test.sh

clean:
	rm -f test_lockstat lockbox-monitor-host readmon

.PHONY: all test clean
