CC ?= cc
CFLAGS = -std=c99 -Wall -Wextra -O2

SRCS = $(wildcard [0-9]*.c)
BINS = $(SRCS:%.c=build/%)

all: $(BINS)

build/%: %.c common.h
	@mkdir -p build
	$(CC) $(CFLAGS) $< -o $@

# 逐个运行；任何一个 CHECK 失败都会让 make 返回非零
test: all
	@for b in $(BINS); do echo "== $$b"; ./$$b || exit 1; done
	@echo "ALL PASSED"

clean:
	rm -rf build

.PHONY: all test clean
