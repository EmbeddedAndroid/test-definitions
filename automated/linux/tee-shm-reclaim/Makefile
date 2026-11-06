# tee-shm-reclaim: needs only a C library and the kernel's linux/tee.h
# (Linux 4.16 or later for TEE_IOC_SHM_REGISTER).
CROSS_COMPILE ?=
CC = $(CROSS_COMPILE)gcc
CFLAGS ?= -O2
LDFLAGS ?=

tee-shm-reclaim: tee-shm-reclaim.c
	$(CC) $(CFLAGS) -Wall -Wextra $(LDFLAGS) -o $@ $<

clean:
	rm -f tee-shm-reclaim
