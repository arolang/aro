# Makefile for plugin-c-collection

CC = clang
CFLAGS = -O2 -fPIC -Wall -Wextra -Iinclude

# Platform-specific settings
UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
    LDFLAGS = -dynamiclib
    OUTPUT = libcollection_plugin.dylib
else ifeq ($(UNAME_S),Linux)
    LDFLAGS = -shared
    OUTPUT = libcollection_plugin.so
else
    LDFLAGS = -shared
    OUTPUT = collection_plugin.dll
endif

SRC = src/collection_plugin.c

.PHONY: all clean test

all: $(OUTPUT)

$(OUTPUT): $(SRC)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

clean:
	rm -f $(OUTPUT)

test: $(OUTPUT)
	@echo "Testing plugin..."
	@if [ -f $(OUTPUT) ]; then echo "Plugin built successfully"; fi
