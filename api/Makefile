# Makefile for the Red Pitaya lockbox library (liblockbox).

# The recursion is unconditional: the sub-make in src/ decides what is out
# of date. As a file target with no prerequisites the library was rebuilt
# only when it was missing, so an ordinary make ignored changed sources
# (and a changed VERSION or commit) and a build needed -B.
.PHONY: all clean install

all:
	$(MAKE) -C src

clean:
	$(MAKE) -C src clean

install:
	$(MAKE) -C src install INSTALL_DIR=$(abspath $(INSTALL_DIR))
