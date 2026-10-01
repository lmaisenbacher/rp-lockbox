# Host test of the SCPI command table (any Linux with gcc; no Red Pitaya):
#
#   make test     every spelling of the PID commands resolves to the right
#                 handler, parameter set and input/output numbers
#
# Only libscpi's matcher (utils.c) is compiled: the library as a whole does
# not build on a 64-bit host with a current gcc. arpa/inet.h supplies the
# declarations utils.c takes for granted.

CC ?= gcc
CFLAGS ?= -g -std=gnu99 -Wall -O2
LIBSCPI = ../scpi-parser/libscpi
INC = -I. -I$(LIBSCPI)/inc -I$(LIBSCPI)/src

all: test_commands

# The command table of the server, one {pattern, callback, tag} per line
commands.inc: ../src/scpi-commands.c
	sed -n 's/^ *{ *\.pattern *= *\("[^"]*"\) *, *\.callback *= *\([A-Za-z_0-9]*\) *,\( *\.tag *= *\([0-9]*\) *,\)\{0,1\} *}.*/{\1, "\2", 0\4},/p' $< > $@

test_commands: test_commands.c $(LIBSCPI)/src/utils.c commands.inc
	$(CC) $(CFLAGS) $(INC) -include arpa/inet.h -o $@ test_commands.c $(LIBSCPI)/src/utils.c

test: all
	./test_commands

clean:
	rm -f test_commands commands.inc

.PHONY: all test clean
