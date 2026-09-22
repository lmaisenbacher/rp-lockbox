# Lockbox server makefile

APP=$(notdir $(CURDIR:%/=%))

# Versioning system
# BUILD_NUMBER ?= 0
# REVISION ?= devbuild
# VER:=$(shell cat info/info.json | grep version | sed -e 's/.*:\ *\"//' | sed -e 's/-.*//')

# Installation directory. It is changed when using the main Makefile++++++
INSTALL_DIR ?= .

LIBSCPI=scpi-parser/libscpi/dist/libscpi.a
SCPISRV=lockbox-server
ARTIFACTS= $(LIBSCPI) $(SCPISRV)

# The server's recursion is unconditional: the sub-make in src/ decides
# what is out of date. As a file target with no prerequisites the server
# was rebuilt only when it was missing, so an ordinary make ignored
# changed sources (and a changed VERSION or commit) and a build needed -B.
# libscpi stays a file target: it is a submodule that changes only when
# the submodule does.
.PHONY: all server

all: $(LIBSCPI) server

server:
	$(MAKE) -C src

$(LIBSCPI):
	$(MAKE) -C scpi-parser CC=$(CROSS_COMPILE)gcc USER_FULL_ERROR_LIST=1

install:
	mkdir -p $(INSTALL_DIR)/bin
	cp $(SCPISRV) $(INSTALL_DIR)/bin

clean:
	$(MAKE) -C src clean
	$(MAKE) -C scpi-parser clean
