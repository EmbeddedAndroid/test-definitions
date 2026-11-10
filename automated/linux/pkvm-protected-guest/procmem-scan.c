// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (c) 2026 Qualcomm Technologies, Inc. and/or its subsidiaries.
 *
 * procmem-scan <pid> <min MiB> <needle>: find the anonymous read-write
 * mappings of <pid> of at least <min MiB> (kvmtool's guest RAM), read them
 * through /proc/<pid>/mem (a host kernel access to the guest's memory) and
 * print "mappings=<n> bytes=<read> zero-pages=<z> unreadable-pages=<u>
 * covered=<bytes> total=<bytes> hits=<count>". A chunk that cannot be read
 * is retried page by page, so every page is either read or counted
 * unreadable and covered == total. Exit 0 when the mappings were read, 1
 * otherwise.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define CHUNK	(1UL << 20)
#define PAGE	4096UL

static unsigned long zero, hits;

static void scan(const char *buf, size_t r, const char *needle, size_t nlen)
{
	for (size_t p = 0; p < r; p += PAGE) {
		const unsigned long *w = (const void *)(buf + p);
		int z = 1;

		for (size_t i = 0; i < PAGE / sizeof(*w) && z; i++)
			z = !w[i];
		zero += z;
	}
	for (const char *s = buf; (s = memmem(s, buf + r - s, needle, nlen)); s += nlen)
		hits++;
}

int main(int argc, char **argv)
{
	unsigned long start, end, minsz, bytes = 0, unreadable = 0, total = 0;
	char path[64], line[512], perms[8], *buf;
	size_t nlen;
	int fd, maps = 0;
	FILE *f;

	if (argc != 4) {
		fprintf(stderr, "usage: %s <pid> <min MiB> <needle>\n", argv[0]);
		return 1;
	}
	minsz = strtoul(argv[2], NULL, 0) << 20;
	nlen = strlen(argv[3]);
	buf = malloc(CHUNK + nlen);
	snprintf(path, sizeof(path), "/proc/%s/maps", argv[1]);
	f = fopen(path, "r");
	snprintf(path, sizeof(path), "/proc/%s/mem", argv[1]);
	fd = open(path, O_RDONLY);
	if (!buf || !f || fd < 0) {
		perror(argv[1]);
		return 1;
	}
	while (fgets(line, sizeof(line), f)) {
		int n = 0;

		if (sscanf(line, "%lx-%lx %7s %*s %*s %*s %n", &start, &end, perms, &n) < 3)
			continue;
		/* Anonymous: no path after the inode column. */
		if (strncmp(perms, "rw", 2) || (line[n] != '\0' && line[n] != '\n'))
			continue;
		if (end - start < minsz)
			continue;
		maps++;
		total += end - start;
		fprintf(stderr, "scan %lx-%lx (%lu MiB)\n", start, end, (end - start) >> 20);
		for (unsigned long a = start; a < end; a += CHUNK) {
			size_t len = end - a < CHUNK ? end - a : CHUNK;
			ssize_t r = pread(fd, buf, len, a);

			if (r == (ssize_t)len) {
				bytes += r;
				scan(buf, r, argv[3], nlen);
				continue;
			}
			for (unsigned long pg = a; pg < a + len; pg += PAGE) {
				r = pread(fd, buf, PAGE, pg);
				if (r != (ssize_t)PAGE) {
					if (!unreadable)
						fprintf(stderr, "first unreadable page %lx: %zd\n", pg, r);
					unreadable++;
					continue;
				}
				bytes += r;
				scan(buf, r, argv[3], nlen);
			}
		}
	}
	printf("mappings=%d bytes=%lu zero-pages=%lu unreadable-pages=%lu covered=%lu total=%lu hits=%lu\n",
	       maps, bytes, zero, unreadable, bytes + unreadable * PAGE, total, hits);
	return maps && bytes ? 0 : 1;
}
