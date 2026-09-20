##
# Copyright (c) 2026, Lothar Maisenbacher
#
# All rights reserved.
#
# lockbox-monitor project file. To build the daemon run 'make all' (after
# the API library, which it links).
#

# Versioning system
VERSION ?= 0.00-0000
REVISION ?= devbuild

# Extensions
CPPEXT   = .c
OBJEXT   = .o

# Directories paths
OBJECTS_DIR = ../obj
OUTPUT_DIR  = ../
SOURCE_DIR  = .
INSTALL_DIR ?= .

# Executable name
TARGET=$(OUTPUT_DIR)/lockbox-monitor

# List of compiled object files
OBJECTS =	lockbox-monitor.o \
		lockstat.o

OBJS = $(patsubst %$(OBJEXT), $(OBJECTS_DIR)/%$(OBJEXT), $(OBJECTS))

# GCC compiling & linking flags
CFLAGS += -g -std=gnu99 -Wall -Werror -fPIC
CFLAGS += -I../../api/include
CFLAGS += -DVERSION=$(VERSION) -DREVISION=$(REVISION)
LDFLAGS=

# -lrt - shm_open(); -lm - sqrt()
LIBPATH= -L ../../api/lib
LIBS= -llockbox -lpthread -lrt -lm

INC= -I../../api/include

# Main GCC executable (used for compiling and linking)
CC=$(CROSS_COMPILE)gcc

all: $(TARGET)

$(OBJECTS_DIR)/%.o:$(SOURCE_DIR)/%.c
	@mkdir -p $(@D)
	$(CC) -c $(CFLAGS) $(INC) $< -o $@

$(TARGET): $(OBJS)
	$(CC) -o $@ $^ $(CFLAGS) $(LIBPATH) $(LIBS)

clean:
	rm -f $(TARGET) $(OBJECTS_DIR)/*.o

# Install target - copies the daemon to $(INSTALL_DIR)/bin.
install:
	mkdir -p $(INSTALL_DIR)/bin
	cp $(TARGET) $(INSTALL_DIR)/bin
