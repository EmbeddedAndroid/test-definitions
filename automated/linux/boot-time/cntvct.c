// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (c) 2026 Qualcomm Technologies, Inc. and/or its subsidiaries.
 *
 * Log CNTVCT_EL0, CNTFRQ_EL0 and CLOCK_BOOTTIME in ns, read together, to
 * the kernel log, which stamps the line with the kernel's own clock.
 */
#include <fcntl.h>
#include <time.h>

int main(void)
{
	struct timespec ts;
	unsigned long cnt, frq;
	char buf[80];
	int fd, n;

	fd = open("/dev/kmsg", O_WRONLY);
	if (fd < 0 || clock_gettime(CLOCK_BOOTTIME, &ts))
		return 1;
	__asm__ volatile("isb; mrs %0, cntvct_el0" : "=r"(cnt));
	__asm__ volatile("mrs %0, cntfrq_el0" : "=r"(frq));
	n = snprintf(buf, sizeof(buf), "boot-time: %lu %lu %lu\n", cnt, frq,
		     (unsigned long)(ts.tv_sec * 1000000000 + ts.tv_nsec));
	return write(fd, buf, n) != n;
}
