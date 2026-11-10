// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (c) 2026 Qualcomm Technologies, Inc. and/or its subsidiaries.
 *
 * tee-protmem <data dir>: secure video with protected buffers, as far as
 * upstream goes (no secure decoder): a protected buffer from the TEE
 * protected-memory heap (lent to OP-TEE over FF-A), an encrypted stream
 * decrypted into it by the secvid TA, frame digests computed on the
 * secure side only, and the host's view of the buffer:
 *
 *   heap-present           /dev/dma_heap/protected,secure-video exists
 *   protected-alloc        a buffer can be allocated from it
 *   protected-mmap-denied  the host cannot map it (system heap control:
 *                          system-mmap)
 *   system-register-fd-refused  only protected heap buffers register
 *   protected-register-fd  it registers with the TEE
 *   ta-refuses-ns-output   the TA will not decrypt into non-secure memory
 *   secure-decrypt         the TA decrypts the stream into it and the
 *                          frame digests match the reference
 *   protected-host-read-hidden  a scan of all RAM through /proc/kcore
 *                          does not find the plaintext (the host CPU
 *                          cannot read the lent pages)
 *   kcore-scan-control     the same scan finds the same marker written
 *                          to a system heap buffer (the probe works)
 *   protected-data-intact  the TA's digests of the buffer after the scan
 *                          still match
 *   protected-data-evict   <rounds> times (default 50): a fresh protected
 *                          buffer (the pool is lent anew), decrypt, evict
 *                          the CPU caches by reading 128 MiB, and the
 *                          TA's digests still match: no line the host
 *                          left dirty before the lend is written back
 *                          over the TA's data
 *
 * When the data does not match, the TA's check command reports how many
 * 64-byte lines differ and how many of those are all zero (never what
 * they hold).
 *
 * The data dir holds stream.enc (ciphertext), stream.sha256 (one hex
 * digest per frame), stream.info ("<frame size> <frames>") and marker.x,
 * a 32-byte marker that occurs in every plaintext page, XORed with 0xa5 so
 * that the marker itself never sits in host memory unless found.
 * Usage: tee-protmem <data dir> [rounds]
 * Output: "<case> pass|fail" lines on stdout, details on stderr.
 */
#define _GNU_SOURCE
#include <elf.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <linux/dma-heap.h>
#include <linux/tee.h>

#define PROT_HEAP	"/dev/dma_heap/protected,secure-video"
#define SYS_HEAP	"/dev/dma_heap/system"
#define MARKER_LEN	32
#define CHUNK		(1UL << 20)
#define MAX_FRAMES	64

#define SECVID_CMD_DECRYPT	0
#define SECVID_CMD_DIGEST	1
#define SECVID_CMD_CHECK	2
#define EVICT_LEN	(128UL << 20)
#define TEE_ERROR_SECURITY	0xffff000f

/* 1b7d45ae-0f97-4ee8-bdeb-f05a852de180, octets in RFC 4122 order */
static const uint8_t secvid_uuid[16] = {
	0x1b, 0x7d, 0x45, 0xae, 0x0f, 0x97, 0x4e, 0xe8,
	0xbd, 0xeb, 0xf0, 0x5a, 0x85, 0x2d, 0xe1, 0x80,
};

struct invoke {
	struct tee_ioctl_invoke_arg arg;
	struct tee_ioctl_param params[4];
};

static void result(const char *name, int pass)
{
	printf("%s %s\n", name, pass ? "pass" : "fail");
	fflush(stdout);
}

static void *read_file(const char *dir, const char *name, size_t *len)
{
	char path[512];
	void *buf = NULL;
	long sz;
	FILE *f;

	snprintf(path, sizeof(path), "%s/%s", dir, name);
	f = fopen(path, "rb");
	if (!f || fseek(f, 0, SEEK_END) || (sz = ftell(f)) <= 0 ||
	    fseek(f, 0, SEEK_SET) || !(buf = malloc(sz + 1)) ||
	    fread(buf, 1, sz, f) != (size_t)sz) {
		fprintf(stderr, "read %s: %s\n", path, strerror(errno));
		exit(1);
	}
	fclose(f);
	((char *)buf)[sz] = 0;
	*len = sz;
	return buf;
}

static int heap_alloc(const char *heap, size_t len)
{
	struct dma_heap_allocation_data d = {
		.len = len, .fd_flags = O_RDWR | O_CLOEXEC,
	};
	int fd = open(heap, O_RDONLY | O_CLOEXEC), rc;

	if (fd < 0)
		return -1;
	rc = ioctl(fd, DMA_HEAP_IOCTL_ALLOC, &d);
	close(fd);
	return rc ? -1 : (int)d.fd;
}

static int register_fd(int tee, int fd, int *id)
{
	struct tee_ioctl_shm_register_fd_data d = { .fd = fd };
	int shm = ioctl(tee, TEE_IOC_SHM_REGISTER_FD, &d);

	*id = d.id;
	return shm;
}

static int register_mem(int tee, void *buf, size_t len, int *id)
{
	struct tee_ioctl_shm_register_data d = {
		.addr = (uintptr_t)buf, .length = len,
	};
	int shm = ioctl(tee, TEE_IOC_SHM_REGISTER, &d);

	*id = d.id;
	return shm;
}

static void memref(struct tee_ioctl_param *p, uint64_t attr, int id, size_t len)
{
	p->attr = attr;
	p->a = 0;
	p->b = len;
	p->c = id;
}

static int invoke(int tee, uint32_t session, uint32_t func, struct invoke *iv,
		  uint32_t *ret)
{
	struct tee_ioctl_buf_data b = {
		.buf_ptr = (uintptr_t)iv, .buf_len = sizeof(*iv),
	};

	iv->arg.func = func;
	iv->arg.session = session;
	iv->arg.num_params = 4;
	if (ioctl(tee, TEE_IOC_INVOKE, &b)) {
		fprintf(stderr, "TEE_IOC_INVOKE %u: %s\n", func, strerror(errno));
		return -1;
	}
	*ret = iv->arg.ret;
	return 0;
}

static void hex(const uint8_t *d, char *out)
{
	for (int i = 0; i < 32; i++)
		sprintf(out + 2 * i, "%02x", d[i]);
}

static int digests_match(const uint8_t *dg, const char *ref, uint32_t frames)
{
	char h[65];

	for (uint32_t n = 0; n < frames; n++) {
		hex(dg + 32 * n, h);
		if (strncmp(h, ref + 65 * n, 64)) {
			fprintf(stderr, "frame %u: %s, reference %.64s\n", n, h, ref + 65 * n);
			return 0;
		}
	}
	return 1;
}

/* The TA's line check of the protected buffer <pid> against ciphertext <cid>. */
static void check(int tee, uint32_t session, int cid, int pid, size_t len,
		  const char *what)
{
	struct invoke iv;
	uint32_t ret = 0;

	memset(&iv, 0, sizeof(iv));
	memref(&iv.params[0], TEE_IOCTL_PARAM_ATTR_TYPE_MEMREF_INPUT, cid, len);
	memref(&iv.params[1], TEE_IOCTL_PARAM_ATTR_TYPE_MEMREF_INPUT, pid, len);
	iv.params[2].attr = TEE_IOCTL_PARAM_ATTR_TYPE_VALUE_OUTPUT;
	iv.params[3].attr = TEE_IOCTL_PARAM_ATTR_TYPE_VALUE_OUTPUT;
	if (invoke(tee, session, SECVID_CMD_CHECK, &iv, &ret) || ret) {
		fprintf(stderr, "%s: check failed, ret 0x%x\n", what, ret);
		return;
	}
	fprintf(stderr, "%s: %llu of %llu lines differ, %llu of them zero, first at 0x%llx\n",
		what, (unsigned long long)iv.params[2].a,
		(unsigned long long)iv.params[3].b,
		(unsigned long long)iv.params[2].b,
		(unsigned long long)iv.params[3].a);
}

/*
 * Count the marker in every RAM segment of /proc/kcore. kcore reads RAM
 * with copy_from_kernel_nofault(), so a page the host stage-2 no longer
 * maps reads as zeros instead of faulting the scan.
 */
static long kcore_scan(const uint8_t *marker_x)
{
	uint8_t *buf = malloc(CHUNK);
	unsigned long scanned = 0;
	Elf64_Ehdr eh;
	Elf64_Phdr *ph;
	long hits = 0;
	int fd = open("/proc/kcore", O_RDONLY | O_CLOEXEC);

	if (fd < 0 || !buf || pread(fd, &eh, sizeof(eh), 0) != sizeof(eh)) {
		fprintf(stderr, "/proc/kcore: %s\n", strerror(errno));
		return -1;
	}
	ph = calloc(eh.e_phnum, sizeof(*ph));
	if (!ph || pread(fd, ph, eh.e_phnum * sizeof(*ph), eh.e_phoff) !=
	    (ssize_t)(eh.e_phnum * sizeof(*ph)))
		return -1;
	for (int i = 0; i < eh.e_phnum; i++) {
		if (ph[i].p_type != PT_LOAD || ph[i].p_paddr == (Elf64_Addr)-1)
			continue;
		for (uint64_t o = 0; o < ph[i].p_filesz; o += CHUNK) {
			size_t len = ph[i].p_filesz - o < CHUNK ? ph[i].p_filesz - o : CHUNK;
			ssize_t r = pread(fd, buf, len, ph[i].p_offset + o);

			if (r <= 0)
				break;
			scanned += r;
			/*
			 * Match byte by byte in the XOR domain: the plaintext
			 * marker must never be stored, or the scan finds its own
			 * copy when it reaches that page.
			 */
			for (ssize_t k = 0; k + MARKER_LEN <= r; k++) {
				int n = 0;

				while (n < MARKER_LEN && (buf[k + n] ^ 0xa5) == marker_x[n])
					n++;
				if (n < MARKER_LEN)
					continue;
				if (hits < 8)
					fprintf(stderr, "marker at PA 0x%llx\n",
						(unsigned long long)(ph[i].p_paddr + o + k));
				hits++;
				k += MARKER_LEN - 1;
			}
		}
	}
	fprintf(stderr, "kcore: scanned %lu MiB of RAM, %ld marker hits\n", scanned >> 20, hits);
	free(ph);
	free(buf);
	close(fd);
	return hits;
}

int main(int argc, char **argv)
{
	size_t enc_len, ref_len, info_len, mk_len;
	uint32_t frame_size = 0, frames = 0, ret = 0, session;
	int tee, pfd, sfd, pshm, pid, cshm, cid, dshm, did, nshm, nid, rc;
	uint8_t *enc, *marker_x, *dg, *ns, *sys;
	const size_t dg_len = MAX_FRAMES * 32;
	char *ref, *info;
	struct invoke iv;
	long hits, rounds = 50, bad = 0;
	volatile uint8_t *evict;
	uint64_t sink = 0;

	if (argc < 2 || argc > 3 || (argc == 3 && (rounds = atol(argv[2])) <= 0)) {
		fprintf(stderr, "usage: %s <data dir> [rounds]\n", argv[0]);
		return 1;
	}
	enc = read_file(argv[1], "stream.enc", &enc_len);
	ref = read_file(argv[1], "stream.sha256", &ref_len);
	info = read_file(argv[1], "stream.info", &info_len);
	marker_x = read_file(argv[1], "marker.x", &mk_len);
	if (sscanf(info, "%u %u", &frame_size, &frames) != 2 || !frames ||
	    frames > MAX_FRAMES || enc_len != (size_t)frame_size * frames ||
	    ref_len < (size_t)frames * 65 || mk_len != MARKER_LEN) {
		fprintf(stderr, "bad stream data in %s\n", argv[1]);
		return 1;
	}

	result("heap-present", !access(PROT_HEAP, R_OK));
	pfd = heap_alloc(PROT_HEAP, enc_len);
	if (pfd < 0)
		fprintf(stderr, "alloc from %s: %s\n", PROT_HEAP, strerror(errno));
	result("protected-alloc", pfd >= 0);
	if (pfd < 0)
		return 0;
	errno = 0;
	result("protected-mmap-denied",
	       mmap(NULL, enc_len, PROT_READ, MAP_SHARED, pfd, 0) == MAP_FAILED);
	fprintf(stderr, "mmap of the protected buffer: %s\n", strerror(errno));

	sfd = heap_alloc(SYS_HEAP, enc_len);
	sys = sfd < 0 ? MAP_FAILED :
	      mmap(NULL, enc_len, PROT_READ | PROT_WRITE, MAP_SHARED, sfd, 0);
	result("system-mmap", sys != MAP_FAILED);

	tee = open("/dev/tee0", O_RDWR | O_CLOEXEC);
	if (tee < 0) {
		perror("/dev/tee0");
		return 1;
	}
	rc = sfd < 0 ? 0 : register_fd(tee, sfd, &cid);
	result("system-register-fd-refused", sfd >= 0 && rc < 0);
	if (rc > 0)
		close(rc);
	pshm = register_fd(tee, pfd, &pid);
	if (pshm < 0)
		fprintf(stderr, "TEE_IOC_SHM_REGISTER_FD: %s\n", strerror(errno));
	result("protected-register-fd", pshm >= 0);
	if (pshm < 0)
		return 0;

	struct {
		struct tee_ioctl_open_session_arg arg;
		struct tee_ioctl_param params[4];
	} os = { 0 };
	struct tee_ioctl_buf_data ob = { .buf_ptr = (uintptr_t)&os, .buf_len = sizeof(os) };

	memcpy(os.arg.uuid, secvid_uuid, sizeof(secvid_uuid));
	os.arg.clnt_login = TEE_IOCTL_LOGIN_PUBLIC;
	os.arg.num_params = 4;
	if (ioctl(tee, TEE_IOC_OPEN_SESSION, &ob) || os.arg.ret) {
		fprintf(stderr, "open session: %s, ret 0x%x origin %u\n", strerror(errno),
			os.arg.ret, os.arg.ret_origin);
		result("ta-session", 0);
		return 0;
	}
	session = os.arg.session;

	/* Non-secure shared memory: the ciphertext and the digests. */
	ns = mmap(NULL, 2 * enc_len + dg_len, PROT_READ | PROT_WRITE,
		  MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (ns == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	memcpy(ns, enc, enc_len);
	dg = ns + 2 * enc_len;
	cshm = register_mem(tee, ns, enc_len, &cid);
	dshm = register_mem(tee, dg, dg_len, &did);
	nshm = register_mem(tee, ns + enc_len, enc_len, &nid);
	if (cshm < 0 || dshm < 0 || nshm < 0) {
		perror("TEE_IOC_SHM_REGISTER");
		return 1;
	}

	/* DRM policy: no plaintext into non-secure memory. */
	memset(&iv, 0, sizeof(iv));
	memref(&iv.params[0], TEE_IOCTL_PARAM_ATTR_TYPE_MEMREF_INPUT, cid, enc_len);
	memref(&iv.params[1], TEE_IOCTL_PARAM_ATTR_TYPE_MEMREF_OUTPUT, nid, enc_len);
	memref(&iv.params[2], TEE_IOCTL_PARAM_ATTR_TYPE_MEMREF_OUTPUT, did, dg_len);
	iv.params[3].attr = TEE_IOCTL_PARAM_ATTR_TYPE_VALUE_INPUT;
	iv.params[3].a = frame_size;
	iv.params[3].b = frames;
	rc = invoke(tee, session, SECVID_CMD_DECRYPT, &iv, &ret);
	fprintf(stderr, "decrypt into non-secure memory: ret 0x%x\n", ret);
	result("ta-refuses-ns-output", !rc && ret == TEE_ERROR_SECURITY);

	memset(dg, 0, dg_len);
	memref(&iv.params[1], TEE_IOCTL_PARAM_ATTR_TYPE_MEMREF_OUTPUT, pid, enc_len);
	rc = invoke(tee, session, SECVID_CMD_DECRYPT, &iv, &ret);
	fprintf(stderr, "decrypt into the protected buffer: ret 0x%x\n", ret);
	result("secure-decrypt", !rc && !ret && digests_match(dg, ref, frames));

	hits = kcore_scan(marker_x);
	result("protected-host-read-hidden", hits == 0);

	if (sys != MAP_FAILED) {
		for (size_t p = 0; p + MARKER_LEN <= enc_len; p += 4096)
			for (int k = 0; k < MARKER_LEN; k++)
				sys[p + k] = marker_x[k] ^ 0xa5;
		hits = kcore_scan(marker_x);
		result("kcore-scan-control", hits >= (long)(enc_len / 4096));
		memset(sys, 0, enc_len);
	} else {
		result("kcore-scan-control", 0);
	}

	memset(&iv, 0, sizeof(iv));
	memset(dg, 0, dg_len);
	memref(&iv.params[0], TEE_IOCTL_PARAM_ATTR_TYPE_MEMREF_INPUT, pid, enc_len);
	memref(&iv.params[1], TEE_IOCTL_PARAM_ATTR_TYPE_MEMREF_OUTPUT, did, dg_len);
	iv.params[2].attr = TEE_IOCTL_PARAM_ATTR_TYPE_VALUE_INPUT;
	iv.params[2].a = frame_size;
	iv.params[2].b = frames;
	rc = invoke(tee, session, SECVID_CMD_DIGEST, &iv, &ret);
	rc = !rc && !ret && digests_match(dg, ref, frames);
	if (!rc)
		check(tee, session, cid, pid, enc_len, "after the scan");
	result("protected-data-intact", rc);

	/* Drop the last buffer so that every round lends the pool anew. */
	close(pshm);
	close(pfd);
	evict = mmap(NULL, EVICT_LEN, PROT_READ | PROT_WRITE,
		     MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE, -1, 0);
	if (evict == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	for (size_t o = 0; o < EVICT_LEN; o += 64)
		evict[o] = (uint8_t)o;
	for (long r = 0; r < rounds; r++) {
		pfd = heap_alloc(PROT_HEAP, enc_len);
		pshm = pfd < 0 ? -1 : register_fd(tee, pfd, &pid);
		if (pshm < 0) {
			fprintf(stderr, "round %ld: alloc/register: %s\n", r, strerror(errno));
			bad++;
			break;
		}
		memset(&iv, 0, sizeof(iv));
		memref(&iv.params[0], TEE_IOCTL_PARAM_ATTR_TYPE_MEMREF_INPUT, cid, enc_len);
		memref(&iv.params[1], TEE_IOCTL_PARAM_ATTR_TYPE_MEMREF_OUTPUT, pid, enc_len);
		memref(&iv.params[2], TEE_IOCTL_PARAM_ATTR_TYPE_MEMREF_OUTPUT, did, dg_len);
		iv.params[3].attr = TEE_IOCTL_PARAM_ATTR_TYPE_VALUE_INPUT;
		iv.params[3].a = frame_size;
		iv.params[3].b = frames;
		rc = invoke(tee, session, SECVID_CMD_DECRYPT, &iv, &ret);
		if (rc || ret || !digests_match(dg, ref, frames)) {
			fprintf(stderr, "round %ld: decrypt ret 0x%x\n", r, ret);
			bad++;
		} else {
			for (size_t o = 0; o < EVICT_LEN; o += 64)
				sink += evict[o];
			memset(&iv, 0, sizeof(iv));
			memref(&iv.params[0], TEE_IOCTL_PARAM_ATTR_TYPE_MEMREF_INPUT, pid, enc_len);
			memref(&iv.params[1], TEE_IOCTL_PARAM_ATTR_TYPE_MEMREF_OUTPUT, did, dg_len);
			iv.params[2].attr = TEE_IOCTL_PARAM_ATTR_TYPE_VALUE_INPUT;
			iv.params[2].a = frame_size;
			iv.params[2].b = frames;
			rc = invoke(tee, session, SECVID_CMD_DIGEST, &iv, &ret);
			if (rc || ret || !digests_match(dg, ref, frames)) {
				char what[32];

				snprintf(what, sizeof(what), "round %ld", r);
				check(tee, session, cid, pid, enc_len, what);
				bad++;
			}
		}
		close(pshm);
		close(pfd);
	}
	fprintf(stderr, "evict: %ld of %ld rounds lost data (sink %llu)\n", bad, rounds,
		(unsigned long long)sink);
	result("protected-data-evict", !bad);
	return 0;
}
