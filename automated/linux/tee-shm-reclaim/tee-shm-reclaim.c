// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (c) 2026 Qualcomm Technologies, Inc. and/or its subsidiaries.
 *
 * Register user memory with the TEE (TEE_IOC_SHM_REGISTER), release it and
 * register the same pages again, for each size in pages given on the
 * command line, for several rounds. With OP-TEE over FF-A a registration is
 * an FFA_MEM_SHARE and a release an FFA_MEM_RECLAIM; under pKVM the
 * hypervisor retrieves the descriptor from the SPMC before each reclaim and
 * refuses to share pages again that it still holds as shared.
 *
 * The pages of each buffer are faulted in even first, then odd, so that
 * neighbouring pages are not physically contiguous; the number of
 * physical ranges is read back from /proc/self/pagemap (needs root) and
 * printed with the FF-A descriptor size, so a case meant to need a
 * fragmented descriptor can check that it did.
 *
 * Usage: tee-shm-reclaim <rounds> <min ranges for the last size> <pages>...
 * Output: one "<case> pass|fail" line per case, "# ..." details. Exits
 * EXIT_SKIP, printing no case, when the TEE cannot register user memory
 * (OP-TEE without dynamic shared memory).
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/tee.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

/* FF-A v1.2: transaction, one endpoint access and composite descriptors */
#define FFA_DESC_FIXED	(48 + 32 + 16)
#define FFA_RANGE_SIZE	16

#define EXIT_SKIP	77

static long page_size;

static int shm_register(int fd, void *buf, size_t len)
{
	struct tee_ioctl_shm_register_data data = {
		.addr = (uintptr_t)buf,
		.length = len,
	};

	return ioctl(fd, TEE_IOC_SHM_REGISTER, &data);
}

static long count_ranges(void *buf, size_t pages)
{
	uint64_t prev = 0;
	uint64_t ent = 0;
	long ranges = 0;
	size_t n = 0;
	int fd = 0;

	fd = open("/proc/self/pagemap", O_RDONLY);
	if (fd < 0)
		return -1;
	for (n = 0; n < pages; n++) {
		off_t offs = ((uintptr_t)buf / page_size + n) * sizeof(ent);
		uint64_t pfn = 0;

		if (pread(fd, &ent, sizeof(ent), offs) != sizeof(ent) ||
		    !(ent >> 63)) {
			ranges = -1;
			break;
		}
		pfn = ent & ((1ULL << 55) - 1);
		if (!pfn) {
			ranges = -1;
			break;
		}
		if (!n || pfn != prev + 1)
			ranges++;
		prev = pfn;
	}
	close(fd);
	return ranges;
}

static int run_case(int tee, size_t pages, int rounds, long min_ranges)
{
	size_t len = pages * page_size;
	long ranges = 0;
	size_t n = 0;
	char *buf = NULL;
	int shm = 0;
	int r = 0;

	buf = mmap(NULL, len, PROT_READ | PROT_WRITE,
		   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (buf == MAP_FAILED) {
		printf("# %zu pages: mmap: %s\n", pages, strerror(errno));
		return -1;
	}
	madvise(buf, len, MADV_NOHUGEPAGE);
	for (n = 0; n < pages; n += 2)
		buf[n * page_size] = 1;
	for (n = 1; n < pages; n += 2)
		buf[n * page_size] = 1;

	for (r = 0; r < rounds; r++) {
		shm = shm_register(tee, buf, len);
		if (shm < 0) {
			printf("# %zu pages round %d: register: %s\n", pages,
			       r, strerror(errno));
			break;
		}
		if (!r) {
			ranges = count_ranges(buf, pages);
			printf("# %zu pages: %ld physical ranges, FF-A descriptor %ld bytes\n",
			       pages, ranges,
			       FFA_DESC_FIXED + ranges * FFA_RANGE_SIZE);
		}
		close(shm);
	}
	munmap(buf, len);

	if (r != rounds)
		return -1;
	if (min_ranges && ranges < min_ranges) {
		printf("# %zu pages: %ld ranges, %ld needed for a fragmented descriptor\n",
		       pages, ranges, min_ranges);
		return -1;
	}
	return 0;
}

int main(int argc, char *argv[])
{
	struct tee_ioctl_version_data vers = { };
	long min_ranges = 0;
	int rounds = 0;
	int ret = 0;
	int tee = 0;
	int i = 0;

	if (argc < 4) {
		fprintf(stderr, "usage: %s <rounds> <min ranges> <pages>...\n",
			argv[0]);
		return 2;
	}
	page_size = sysconf(_SC_PAGESIZE);
	rounds = atoi(argv[1]);
	min_ranges = atol(argv[2]);

	tee = open("/dev/tee0", O_RDWR);
	if (tee < 0 || ioctl(tee, TEE_IOC_VERSION, &vers)) {
		printf("# /dev/tee0: %s\n", strerror(errno));
		printf("tee-shm-reclaim-open fail\n");
		return 1;
	}
	printf("# TEE implementation %u, gen_caps 0x%x\n", vers.impl_id,
	       vers.gen_caps);
	if (!(vers.gen_caps & TEE_GEN_CAP_REG_MEM)) {
		printf("# the TEE cannot register user memory (no TEE_GEN_CAP_REG_MEM: no dynamic shared memory)\n");
		close(tee);
		return EXIT_SKIP;
	}
	printf("tee-shm-reclaim-open pass\n");

	for (i = 3; i < argc; i++) {
		size_t pages = strtoul(argv[i], NULL, 0);
		int rc = run_case(tee, pages, rounds,
				  i == argc - 1 ? min_ranges : 0);

		printf("tee-shm-reclaim-%zup %s\n", pages, rc ? "fail" : "pass");
		if (rc)
			ret = 1;
	}
	close(tee);
	return ret;
}
