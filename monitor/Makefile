# Lockbox monitor daemon makefile

# Installation directory. It is changed when using the main Makefile
INSTALL_DIR ?= .

MONITOR=lockbox-monitor

all: $(MONITOR)

$(MONITOR):
	$(MAKE) -C src

# Host build and tests of the lock-drop state machine and the shared block
# (no Red Pitaya needed; see test/Makefile)
test:
	$(MAKE) -C test test

install:
	mkdir -p $(INSTALL_DIR)/bin
	cp $(MONITOR) $(INSTALL_DIR)/bin

clean:
	$(MAKE) -C src clean
	$(MAKE) -C test clean

.PHONY: all test install clean $(MONITOR)
