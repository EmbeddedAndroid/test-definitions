// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (c) 2026 Qualcomm Technologies, Inc. and/or its subsidiaries.
 *
 * iris-secure <data dir>: Iris secure decode and encode in protected
 * DMA-bufs (TEE protected heap, lent to OP-TEE over FF-A), the codec's
 * secure context banks owned by the hypervisor (pKVM), and the controls:
 *
 *   ref-decode             non-secure decode of the clip into system heap
 *                          buffers; per-frame SHA-256 computed by the host
 *   secure-decode          the clip decrypted by the secvid TA into
 *                          protected bitstream buffers, decoded in a secure
 *                          session into protected frames, whose SHA-256 the
 *                          TA computes: equal to ref-decode, frame by frame
 *   secure-encode          raw frames decrypted by the TA into protected
 *                          buffers, encoded in a secure session into
 *                          protected bitstream buffers, decoded back in a
 *                          secure session: the TA's luma MSE against the
 *                          source frames gives at least MIN_PSNR dB
 *   nonsecure-protected-refused   a non-secure session refuses a
 *                          protected buffer (driver)
 *   secure-unprotected-refused    a secure session refuses a system heap
 *                          buffer (driver)
 *   hyp-refuses-unlent     with the driver check off (test knob), the
 *                          hypervisor refuses to map memory that is not
 *                          lent into a secure bank
 *   nonsecure-dma-blocked  with the driver check off, a non-secure decode
 *                          into a protected buffer the TA filled: the SMMU
 *                          shadow stage 2 faults the codec's writes and the
 *                          TA finds the buffer unchanged
 *   aimed-dma-host-page    control for the aimed cases below: the first
 *                          page of a non-secure decode's frames aimed (test
 *                          knob, codec's host IOMMU domain) at a page the
 *                          host owns: no shadow fault, the codec writes it
 *   hyp-data-dma-read-blocked, hyp-data-dma-write-blocked,
 *   iommu-pool-dma-read-blocked, iommu-pool-dma-write-blocked
 *                          the same, aimed at a page of hypervisor data and
 *                          at the shadow stage 2's level 1 table (IOMMU
 *                          pool): the input (codec reads) and the frames
 *                          (codec writes) fault in the shadow bank and the
 *                          hypervisor's checksum of the page is unchanged;
 *                          a write case is skipped if its read reached the
 *                          page, so a kernel with the hole is not corrupted
 *   other-dma-unaffected   (iris-secure.sh) the faults leave the other
 *                          masters behind the SMMU working
 *
 * The data dir holds clip.h264 (Annex B with access unit delimiters),
 * clip.idx (one access unit size per line), clip.enc (each access unit
 * encrypted on its own with the secvid test key), raw.enc (NV12 frames,
 * each encrypted on its own), raw.info ("<width> <height> <frames>").
 * Usage: iris-secure <data dir> [min psnr]
 * Output: "<case> pass|fail|skip" lines on stdout, details on stderr.
 */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <linux/dma-heap.h>
#include <linux/tee.h>
#include <linux/videodev2.h>

#define PROT_HEAP	"/dev/dma_heap/protected,secure-video"
#define SYS_HEAP	"/dev/dma_heap/system"
#define CMA_HEAP	"/dev/dma_heap/default_cma_region"
#define KNOB		"/sys/module/qcom_iris/parameters/secure_test_skip_heap_check"
#define AIM		"/sys/module/qcom_iris/parameters/secure_test_dma_target"
#define AIM_WRITE	"/sys/module/qcom_iris/parameters/secure_test_dma_write"
#define GUARD		"/sys/kernel/debug/arm_smmu_pkvm"
#define CID_SECURE	(V4L2_CID_USER_BASE | 0x1f00)
#define MAX_AU		256
#define NBUF_OUT	4
#define NBUF_CAP	8
#define TIMEOUT_MS	5000

#define SECVID_CMD_DECRYPT	0
#define SECVID_CMD_DIGEST	1
#define SECVID_CMD_CHECK	2
#define SECVID_CMD_MSE		3

static const uint8_t secvid_uuid[16] = {
	0x1b, 0x7d, 0x45, 0xae, 0x0f, 0x97, 0x4e, 0xe8,
	0xbd, 0xeb, 0xf0, 0x5a, 0x85, 0x2d, 0xe1, 0x80,
};

struct invoke {
	struct tee_ioctl_invoke_arg arg;
	struct tee_ioctl_param params[4];
};

/* ---- SHA-256 (FIPS 180-4) for the host side reference ---- */
static const uint32_t K256[64] = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void sha256_block(uint32_t h[8], const uint8_t *p)
{
	uint32_t w[64], a, b, c, d, e, f, g, k, t1, t2;
	int i;

	for (i = 0; i < 16; i++)
		w[i] = (uint32_t)p[4 * i] << 24 | p[4 * i + 1] << 16 | p[4 * i + 2] << 8 | p[4 * i + 3];
	for (i = 16; i < 64; i++)
		w[i] = (ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ (w[i - 2] >> 10)) + w[i - 7] +
		       (ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ (w[i - 15] >> 3)) + w[i - 16];
	a = h[0]; b = h[1]; c = h[2]; d = h[3]; e = h[4]; f = h[5]; g = h[6]; k = h[7];
	for (i = 0; i < 64; i++) {
		t1 = k + (ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25)) + ((e & f) ^ (~e & g)) + K256[i] + w[i];
		t2 = (ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
		k = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
	}
	h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += k;
}

static void sha256(const uint8_t *d, size_t len, uint8_t out[32])
{
	uint32_t h[8] = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
			  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 };
	uint8_t tail[128] = { 0 };
	size_t i, n = len & ~(size_t)63, r = len - n, tl;
	uint64_t bits = (uint64_t)len * 8;

	for (i = 0; i < n; i += 64)
		sha256_block(h, d + i);
	memcpy(tail, d + n, r);
	tail[r] = 0x80;
	tl = r < 56 ? 64 : 128;
	for (i = 0; i < 8; i++)
		tail[tl - 1 - i] = bits >> (8 * i);
	for (i = 0; i < tl; i += 64)
		sha256_block(h, tail + i);
	for (i = 0; i < 8; i++) {
		out[4 * i] = h[i] >> 24; out[4 * i + 1] = h[i] >> 16;
		out[4 * i + 2] = h[i] >> 8; out[4 * i + 3] = h[i];
	}
}

/* ---- helpers ---- */
static int tee_fd = -1;
static uint32_t session;
static unsigned int width, height, raw_frames;
static size_t nau, au_len[MAX_AU], au_off[MAX_AU];
static uint8_t *clip, *clip_enc, *raw_enc;
static size_t clip_size, raw_size;

static void result(const char *name, const char *r)
{
	printf("%s %s\n", name, r);
	fflush(stdout);
}

/* The driver's log lines for the hypervisor refusing a pixel bank mapping */
static int refusals(void)
{
	FILE *k = popen("dmesg | grep -c 'secure bank 1 refused .*: -1$'", "r");
	int n = 0;

	if (k) {
		if (fscanf(k, "%d", &n) != 1)
			n = 0;
		pclose(k);
	}
	return n;
}

/* The kernel log lines added since the last call, on stderr (none if !tag) */
static void kmsg(const char *tag)
{
	static long seen;
	char line[512];
	long n = 0;
	FILE *k = popen("dmesg", "r");

	if (!k)
		return;
	while (fgets(line, sizeof(line), k))
		if (++n > seen && tag)
			fprintf(stderr, "%s: kmsg: %s", tag, line);
	pclose(k);
	seen = n;
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

static size_t page_align(size_t n)
{
	size_t p = sysconf(_SC_PAGESIZE);

	return (n + p - 1) & ~(p - 1);
}

static int heap_alloc(const char *heap, size_t len)
{
	struct dma_heap_allocation_data d = {
		.len = page_align(len), .fd_flags = O_RDWR | O_CLOEXEC,
	};
	int fd = open(heap, O_RDONLY | O_CLOEXEC), rc;

	if (fd < 0)
		return -1;
	rc = ioctl(fd, DMA_HEAP_IOCTL_ALLOC, &d);
	close(fd);
	return rc ? -1 : (int)d.fd;
}

static void knob(int on)
{
	int fd = open(KNOB, O_WRONLY);

	if (fd >= 0) {
		if (write(fd, on ? "1" : "0", 1) != 1)
			fprintf(stderr, "write %s: %s\n", KNOB, strerror(errno));
		close(fd);
	}
}

static int tee_open(void)
{
	struct tee_ioctl_open_session_arg *a;
	struct tee_ioctl_buf_data b;
	uint8_t buf[sizeof(*a) + 4 * sizeof(struct tee_ioctl_param)];

	tee_fd = open("/dev/tee0", O_RDWR);
	if (tee_fd < 0)
		return -1;
	memset(buf, 0, sizeof(buf));
	a = (void *)buf;
	memcpy(a->uuid, secvid_uuid, 16);
	a->clnt_login = TEE_IOCTL_LOGIN_PUBLIC;
	a->num_params = 4;
	b.buf_ptr = (uintptr_t)buf;
	b.buf_len = sizeof(buf);
	if (ioctl(tee_fd, TEE_IOC_OPEN_SESSION, &b) || a->ret) {
		fprintf(stderr, "open secvid TA: %s ret %#x\n", strerror(errno), a->ret);
		return -1;
	}
	session = a->session;
	return 0;
}

static int register_fd(int fd, int *id)
{
	struct tee_ioctl_shm_register_fd_data d = { .fd = fd };
	int shm = ioctl(tee_fd, TEE_IOC_SHM_REGISTER_FD, &d);

	*id = d.id;
	return shm;
}

static int register_mem(void *buf, size_t len, int *id)
{
	struct tee_ioctl_shm_register_data d = {
		.addr = (uintptr_t)buf, .length = len,
	};
	int shm = ioctl(tee_fd, TEE_IOC_SHM_REGISTER, &d);

	*id = d.id;
	return shm;
}

static void memref(struct tee_ioctl_param *p, uint64_t attr, int id, size_t off, size_t len)
{
	p->attr = attr;
	p->a = off;
	p->b = len;
	p->c = id;
}

static int invoke(uint32_t func, struct invoke *iv)
{
	struct tee_ioctl_buf_data b = {
		.buf_ptr = (uintptr_t)iv, .buf_len = sizeof(*iv),
	};

	iv->arg.func = func;
	iv->arg.session = session;
	iv->arg.num_params = 4;
	if (ioctl(tee_fd, TEE_IOC_INVOKE, &b)) {
		fprintf(stderr, "TEE_IOC_INVOKE %u: %s\n", func, strerror(errno));
		return -1;
	}
	if (iv->arg.ret)
		fprintf(stderr, "TA command %u: ret %#x\n", func, iv->arg.ret);
	return iv->arg.ret ? -1 : 0;
}

/* Decrypt <len> bytes of ciphertext into a protected buffer, in the TA */
static int ta_decrypt(const uint8_t *ct, size_t len, int prot_fd)
{
	uint8_t *ns = NULL, dg[32];
	int cid, pid, did, cs, ps, ds, rc = -1;
	size_t nsl = page_align(len);
	struct invoke iv;

	if (posix_memalign((void **)&ns, sysconf(_SC_PAGESIZE), nsl))
		return -1;
	memcpy(ns, ct, len);
	cs = register_mem(ns, nsl, &cid);
	ps = register_fd(prot_fd, &pid);
	ds = register_mem(dg, sizeof(dg), &did);
	if (cs >= 0 && ps >= 0 && ds >= 0) {
		memset(&iv, 0, sizeof(iv));
		memref(&iv.params[0], TEE_IOCTL_PARAM_ATTR_TYPE_MEMREF_INPUT, cid, 0, len);
		memref(&iv.params[1], TEE_IOCTL_PARAM_ATTR_TYPE_MEMREF_OUTPUT, pid, 0, len);
		memref(&iv.params[2], TEE_IOCTL_PARAM_ATTR_TYPE_MEMREF_OUTPUT, did, 0, 32);
		iv.params[3].attr = TEE_IOCTL_PARAM_ATTR_TYPE_VALUE_INPUT;
		iv.params[3].a = len;
		iv.params[3].b = 1;
		rc = invoke(SECVID_CMD_DECRYPT, &iv);
	}
	if (cs >= 0) close(cs);
	if (ps >= 0) close(ps);
	if (ds >= 0) close(ds);
	free(ns);
	return rc;
}

/* SHA-256 of the first <len> bytes of a protected buffer, in the TA */
static int ta_digest(int prot_fd, size_t len, uint8_t out[32])
{
	int pid, did, ps, ds, rc = -1;
	uint8_t *dg = NULL;
	struct invoke iv;

	if (posix_memalign((void **)&dg, sysconf(_SC_PAGESIZE), sysconf(_SC_PAGESIZE)))
		return -1;
	ps = register_fd(prot_fd, &pid);
	ds = register_mem(dg, sysconf(_SC_PAGESIZE), &did);
	if (ps >= 0 && ds >= 0) {
		memset(&iv, 0, sizeof(iv));
		memref(&iv.params[0], TEE_IOCTL_PARAM_ATTR_TYPE_MEMREF_INPUT, pid, 0, len);
		memref(&iv.params[1], TEE_IOCTL_PARAM_ATTR_TYPE_MEMREF_OUTPUT, did, 0, 32);
		iv.params[2].attr = TEE_IOCTL_PARAM_ATTR_TYPE_VALUE_INPUT;
		iv.params[2].a = len;
		iv.params[2].b = 1;
		rc = invoke(SECVID_CMD_DIGEST, &iv);
		memcpy(out, dg, 32);
	}
	if (ps >= 0) close(ps);
	if (ds >= 0) close(ds);
	free(dg);
	return rc;
}

/* Lines of a protected buffer that differ from the decrypted ciphertext */
static int ta_check(const uint8_t *ct, size_t len, int prot_fd, uint32_t *diff)
{
	int cid, pid, cs, ps, rc = -1;
	uint8_t *ns = NULL;
	struct invoke iv;

	if (posix_memalign((void **)&ns, sysconf(_SC_PAGESIZE), len))
		return -1;
	memcpy(ns, ct, len);
	cs = register_mem(ns, len, &cid);
	ps = register_fd(prot_fd, &pid);
	if (cs >= 0 && ps >= 0) {
		memset(&iv, 0, sizeof(iv));
		memref(&iv.params[0], TEE_IOCTL_PARAM_ATTR_TYPE_MEMREF_INPUT, cid, 0, len);
		memref(&iv.params[1], TEE_IOCTL_PARAM_ATTR_TYPE_MEMREF_INPUT, pid, 0, len);
		iv.params[2].attr = TEE_IOCTL_PARAM_ATTR_TYPE_VALUE_OUTPUT;
		iv.params[3].attr = TEE_IOCTL_PARAM_ATTR_TYPE_VALUE_OUTPUT;
		rc = invoke(SECVID_CMD_CHECK, &iv);
		*diff = iv.params[2].a;
	}
	if (cs >= 0) close(cs);
	if (ps >= 0) close(ps);
	free(ns);
	return rc;
}

static int ta_mse(const uint8_t *ct, size_t len, int prot_fd, uint32_t *mse)
{
	int cid, pid, cs, ps, rc = -1;
	size_t nsl = page_align(len);
	uint8_t *ns = NULL;
	struct invoke iv;

	if (posix_memalign((void **)&ns, sysconf(_SC_PAGESIZE), nsl))
		return -1;
	memcpy(ns, ct, len);
	cs = register_mem(ns, nsl, &cid);
	ps = register_fd(prot_fd, &pid);
	if (cs >= 0 && ps >= 0) {
		memset(&iv, 0, sizeof(iv));
		memref(&iv.params[0], TEE_IOCTL_PARAM_ATTR_TYPE_MEMREF_INPUT, cid, 0, len);
		memref(&iv.params[1], TEE_IOCTL_PARAM_ATTR_TYPE_MEMREF_INPUT, pid, 0, len);
		iv.params[2].attr = TEE_IOCTL_PARAM_ATTR_TYPE_VALUE_OUTPUT;
		iv.params[3].attr = TEE_IOCTL_PARAM_ATTR_TYPE_VALUE_INPUT;
		iv.params[3].a = len;
		rc = invoke(SECVID_CMD_MSE, &iv);
		*mse = iv.params[2].a;
	}
	if (cs >= 0) close(cs);
	if (ps >= 0) close(ps);
	free(ns);
	return rc;
}

static void guard_report(const char *when, unsigned long long *faults,
			 unsigned long long *far)
{
	char line[256];
	FILE *f = fopen(GUARD, "r");

	*faults = 0;
	*far = 0;
	if (!f)
		return;
	while (fgets(line, sizeof(line), f)) {
		fprintf(stderr, "%s: %s", when, line);
		sscanf(line, "faults %llu fsr %*s far %llx", faults, far);
	}
	fclose(f);
}

/* ---- V4L2 ---- */
static int find_codec(int encoder)
{
	struct v4l2_capability cap;
	struct v4l2_fmtdesc fd;
	char path[64];
	int i, fdv;

	for (i = 0; i < 64; i++) {
		snprintf(path, sizeof(path), "/dev/video%d", i);
		fdv = open(path, O_RDWR | O_NONBLOCK);
		if (fdv < 0)
			continue;
		if (!ioctl(fdv, VIDIOC_QUERYCAP, &cap) && strstr((char *)cap.driver, "iris")) {
			memset(&fd, 0, sizeof(fd));
			fd.type = encoder ? V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE :
					    V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
			for (fd.index = 0; !ioctl(fdv, VIDIOC_ENUM_FMT, &fd); fd.index++)
				if (fd.pixelformat == V4L2_PIX_FMT_H264)
					return fdv;
		}
		close(fdv);
	}
	return -1;
}

static int set_secure(int v, int on)
{
	struct v4l2_control c = { .id = CID_SECURE, .value = on };

	return ioctl(v, VIDIOC_S_CTRL, &c);
}

static int set_fmt(int v, uint32_t type, uint32_t pix, struct v4l2_format *f)
{
	memset(f, 0, sizeof(*f));
	f->type = type;
	f->fmt.pix_mp.width = width;
	f->fmt.pix_mp.height = height;
	f->fmt.pix_mp.pixelformat = pix;
	f->fmt.pix_mp.num_planes = 1;
	if (ioctl(v, VIDIOC_S_FMT, f)) {
		fprintf(stderr, "S_FMT %u: %s\n", type, strerror(errno));
		return -1;
	}
	return 0;
}

static int reqbufs(int v, uint32_t type, uint32_t mem, unsigned int n)
{
	struct v4l2_requestbuffers r = { .count = n, .type = type, .memory = mem };

	if (ioctl(v, VIDIOC_REQBUFS, &r)) {
		fprintf(stderr, "REQBUFS %u: %s\n", type, strerror(errno));
		return -1;
	}
	return r.count;
}

static int qbuf(int v, uint32_t type, uint32_t mem, int idx, int fd, size_t len, size_t used)
{
	struct v4l2_plane pl = { .bytesused = used, .length = len };
	struct v4l2_buffer b = {
		.type = type, .memory = mem, .index = idx, .length = 1, .m.planes = &pl,
	};

	if (mem == V4L2_MEMORY_DMABUF)
		pl.m.fd = fd;
	b.timestamp.tv_usec = idx + 1;
	return ioctl(v, VIDIOC_QBUF, &b);
}

static int dqbuf(int v, uint32_t type, uint32_t mem, struct v4l2_buffer *b, struct v4l2_plane *pl)
{
	memset(b, 0, sizeof(*b));
	memset(pl, 0, sizeof(*pl));
	b->type = type;
	b->memory = mem;
	b->length = 1;
	b->m.planes = pl;
	return ioctl(v, VIDIOC_DQBUF, b);
}

static int stream(int v, uint32_t type, int on)
{
	return ioctl(v, on ? VIDIOC_STREAMON : VIDIOC_STREAMOFF, &type);
}

/*
 * A decode session. Input: access units from <aus> (plaintext copied into
 * MMAP buffers, or protected DMA-bufs filled by the caller); output into
 * DMA-bufs from <cap_heap>; <frame> is called per decoded frame.
 */
struct decode {
	int secure;
	int nin;			/* access units */
	int in_fd[MAX_AU];		/* protected input DMA-bufs, or -1 */
	size_t in_used[MAX_AU];
	size_t in_size;			/* their size */
	const char *cap_heap;
	int cap_fd[NBUF_CAP];
	size_t cap_len;
	int frames;
	uint8_t digest[MAX_AU][32];
	int (*frame)(struct decode *d, int fd, size_t used, int n);
	int prefill;			/* the TA fills capture buffers with raw frame 0 */
	int refill;			/* the TA decrypts each access unit of the clip
					   into one of NBUF_OUT protected buffers */
	int ring[NBUF_OUT];
};

/* Protected input buffer <slot> holding access unit <n>, decrypted by the TA */
static int refill_slot(struct decode *d, int slot, size_t size, int n)
{
	if (d->ring[slot] <= 0)
		d->ring[slot] = heap_alloc(PROT_HEAP, size);
	if (d->ring[slot] < 0 || ta_decrypt(clip_enc + au_off[n], au_len[n], d->ring[slot]))
		return -1;
	return d->ring[slot];
}

static int decode_run(struct decode *d)
{
	const uint32_t OUT = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
	const uint32_t CAP = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	struct v4l2_event_subscription sub = { .type = V4L2_EVENT_SOURCE_CHANGE };
	uint32_t in_mem = d->secure ? V4L2_MEMORY_DMABUF : V4L2_MEMORY_MMAP;
	void *in_map[NBUF_OUT] = { 0 };
	size_t in_len = 0;
	struct v4l2_format fo, fc;
	struct v4l2_buffer b;
	struct v4l2_plane pl;
	struct v4l2_decoder_cmd stop = { .cmd = V4L2_DEC_CMD_STOP };
	int v, i, next = 0, nout, cap_on = 0, rc = -1, done = 0;
	struct timespec t0, t;

	d->frames = 0;
	v = find_codec(0);
	if (v < 0) {
		fprintf(stderr, "no iris decoder\n");
		return -1;
	}
	if (d->secure && set_secure(v, 1)) {
		fprintf(stderr, "secure control: %s\n", strerror(errno));
		goto out;
	}
	if (set_fmt(v, OUT, V4L2_PIX_FMT_H264, &fo) || set_fmt(v, CAP, V4L2_PIX_FMT_NV12, &fc))
		goto out;
	ioctl(v, VIDIOC_SUBSCRIBE_EVENT, &sub);
	nout = reqbufs(v, OUT, in_mem, NBUF_OUT);
	if (nout <= 0)
		goto out;
	in_len = fo.fmt.pix_mp.plane_fmt[0].sizeimage;
	if (!d->secure) {
		for (i = 0; i < nout; i++) {
			struct v4l2_buffer qb = { .type = OUT, .memory = in_mem, .index = i,
						  .length = 1, .m.planes = &pl };

			memset(&pl, 0, sizeof(pl));
			if (ioctl(v, VIDIOC_QUERYBUF, &qb))
				goto out;
			in_map[i] = mmap(NULL, pl.length, PROT_READ | PROT_WRITE, MAP_SHARED, v,
					 pl.m.mem_offset);
			if (in_map[i] == MAP_FAILED)
				goto out;
			in_len = pl.length;
		}
	}
	if (stream(v, OUT, 1))
		goto out;

	clock_gettime(CLOCK_MONOTONIC, &t0);
	/* Prime the input queue */
	for (i = 0; i < nout && next < d->nin; i++, next++) {
		if (d->refill) {
			int f = refill_slot(d, i, in_len, next);

			rc = f < 0 ? -1 : qbuf(v, OUT, in_mem, i, f, page_align(in_len), au_len[next]);
		} else if (d->secure) {
			rc = qbuf(v, OUT, in_mem, i, d->in_fd[next], d->in_size,
				  d->in_used[next]);
		} else {
			memcpy(in_map[i], clip + au_off[next], au_len[next]);
			rc = qbuf(v, OUT, in_mem, i, -1, in_len, au_len[next]);
		}
		if (rc) {
			fprintf(stderr, "QBUF input %d: %s\n", next, strerror(errno));
			rc = -1;
			goto out;
		}
	}

	while (!done) {
		struct pollfd p = { .fd = v, .events = POLLIN | POLLOUT | POLLPRI };

		clock_gettime(CLOCK_MONOTONIC, &t);
		if ((t.tv_sec - t0.tv_sec) * 1000 + (t.tv_nsec - t0.tv_nsec) / 1000000 > TIMEOUT_MS) {
			fprintf(stderr, "decode timed out after %d frames, %d of %d inputs queued, capture %s\n",
				d->frames, next, d->nin, cap_on ? "on" : "never configured");
			break;
		}
		if (poll(&p, 1, 200) <= 0)
			continue;
		if (p.revents & POLLPRI) {
			struct v4l2_event ev;

			while (!ioctl(v, VIDIOC_DQEVENT, &ev)) {
				if (ev.type != V4L2_EVENT_SOURCE_CHANGE || cap_on)
					continue;
				if (ioctl(v, VIDIOC_G_FMT, &fc))
					goto out;
				d->cap_len = fc.fmt.pix_mp.plane_fmt[0].sizeimage;
				if (reqbufs(v, CAP, V4L2_MEMORY_DMABUF, NBUF_CAP) <= 0)
					goto out;
				for (i = 0; i < NBUF_CAP; i++) {
					d->cap_fd[i] = heap_alloc(d->cap_heap, d->cap_len);
					if (d->cap_fd[i] >= 0 && d->prefill &&
					    ta_decrypt(raw_enc, (size_t)width * height * 3 / 2,
						       d->cap_fd[i]))
						fprintf(stderr, "prefill capture %d failed\n", i);
					if (d->cap_fd[i] < 0 ||
					    qbuf(v, CAP, V4L2_MEMORY_DMABUF, i, d->cap_fd[i],
						 page_align(d->cap_len), 0)) {
						fprintf(stderr, "QBUF capture %d: %s\n", i, strerror(errno));
						rc = -2;
						goto out;
					}
				}
				if (stream(v, CAP, 1))
					goto out;
				cap_on = 1;
			}
		}
		/* Refill consumed input buffers */
		while (!dqbuf(v, OUT, in_mem, &b, &pl)) {
			if (next < d->nin) {
				if (d->refill) {
					int f = refill_slot(d, b.index, in_len, next);

					rc = f < 0 ? -1 : qbuf(v, OUT, in_mem, b.index, f,
							       page_align(in_len), au_len[next]);
				} else if (d->secure)
					rc = qbuf(v, OUT, in_mem, b.index, d->in_fd[next],
						  d->in_size, d->in_used[next]);
				else {
					memcpy(in_map[b.index], clip + au_off[next], au_len[next]);
					rc = qbuf(v, OUT, in_mem, b.index, -1, in_len, au_len[next]);
				}
				if (rc)
					goto out;
				if (++next == d->nin)
					ioctl(v, VIDIOC_DECODER_CMD, &stop);
			}
		}
		if (next == d->nin && d->nin <= nout && !cap_on)
			ioctl(v, VIDIOC_DECODER_CMD, &stop);
		while (cap_on && !dqbuf(v, CAP, V4L2_MEMORY_DMABUF, &b, &pl)) {
			if (pl.bytesused && d->frame &&
			    d->frame(d, d->cap_fd[b.index], pl.bytesused, d->frames) == 0)
				d->frames++;
			if (b.flags & V4L2_BUF_FLAG_LAST) {
				done = 1;
				break;
			}
			qbuf(v, CAP, V4L2_MEMORY_DMABUF, b.index, d->cap_fd[b.index],
			     page_align(d->cap_len), 0);
		}
	}
	rc = done ? 0 : -1;
out:
	stream(v, OUT, 0);
	if (cap_on)
		stream(v, CAP, 0);
	for (i = 0; i < NBUF_OUT; i++)
		if (in_map[i] && in_map[i] != MAP_FAILED)
			munmap(in_map[i], in_len);
	close(v);
	return rc;
}

static int frame_sha(struct decode *d, int fd, size_t used, int n)
{
	void *m = mmap(NULL, page_align(used), PROT_READ, MAP_SHARED, fd, 0);

	if (m == MAP_FAILED || n >= MAX_AU)
		return -1;
	sha256(m, used, d->digest[n]);
	munmap(m, page_align(used));
	return 0;
}

static int frame_ta(struct decode *d, int fd, size_t used, int n)
{
	return n < MAX_AU ? ta_digest(fd, used, d->digest[n]) : -1;
}

static void hexs(const uint8_t *d, char *o)
{
	for (int i = 0; i < 32; i++)
		sprintf(o + 2 * i, "%02x", d[i]);
}

/* The clip in protected input buffers, decrypted by the TA as they are queued */
static int fill_protected_clip(struct decode *d)
{
	d->nin = nau;
	d->refill = 1;
	return 0;
}

static void close_fds(int *fd, int n)
{
	for (int i = 0; i < n; i++)
		if (fd[i] > 0)
			close(fd[i]);
}

/* ---- encode ---- */
static size_t dec_in_size(void)
{
	struct v4l2_format f;
	size_t s = 0;
	int v = find_codec(0);

	if (v >= 0 && !set_fmt(v, V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, V4L2_PIX_FMT_H264, &f))
		s = f.fmt.pix_mp.plane_fmt[0].sizeimage;
	if (v >= 0)
		close(v);
	return page_align(s);
}

static int encode_run(int nframes, int *bs_fd, size_t *bs_used, size_t *bs_size)
{
	const uint32_t OUT = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
	const uint32_t CAP = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	size_t fsize = (size_t)width * height * 3 / 2, in_len, cap_len;
	int v, i, in_fd[MAX_AU] = { 0 }, nout, got = 0, rc = -1;
	struct v4l2_encoder_cmd stop = { .cmd = V4L2_ENC_CMD_STOP };
	struct v4l2_format fo, fc;
	struct v4l2_buffer b;
	struct v4l2_plane pl;
	struct timespec t0, t;

	v = find_codec(1);
	if (v < 0) {
		fprintf(stderr, "no iris encoder\n");
		return -1;
	}
	if (set_secure(v, 1)) {
		fprintf(stderr, "secure control: %s\n", strerror(errno));
		goto out;
	}
	if (set_fmt(v, CAP, V4L2_PIX_FMT_H264, &fc) || set_fmt(v, OUT, V4L2_PIX_FMT_NV12, &fo))
		goto out;
	in_len = fo.fmt.pix_mp.plane_fmt[0].sizeimage;
	cap_len = fc.fmt.pix_mp.plane_fmt[0].sizeimage;
	if (fo.fmt.pix_mp.plane_fmt[0].bytesperline != width || in_len < fsize) {
		fprintf(stderr, "encoder input layout %u x %u bytes, need stride %u\n",
			fo.fmt.pix_mp.plane_fmt[0].bytesperline, (unsigned int)in_len, width);
		goto out;
	}
	if (dec_in_size() > page_align(cap_len))
		cap_len = dec_in_size();
	*bs_size = page_align(cap_len);
	nout = reqbufs(v, OUT, V4L2_MEMORY_DMABUF, nframes);
	if (nout < nframes || reqbufs(v, CAP, V4L2_MEMORY_DMABUF, nframes) < nframes)
		goto out;
	for (i = 0; i < nframes; i++) {
		in_fd[i] = heap_alloc(PROT_HEAP, in_len);
		bs_fd[i] = heap_alloc(PROT_HEAP, cap_len);
		if (in_fd[i] < 0 || bs_fd[i] < 0 ||
		    ta_decrypt(raw_enc + i * fsize, fsize, in_fd[i])) {
			fprintf(stderr, "protected encode buffers %d\n", i);
			goto out;
		}
	}
	for (i = 0; i < nframes; i++)
		if (qbuf(v, CAP, V4L2_MEMORY_DMABUF, i, bs_fd[i], page_align(cap_len), 0)) {
			fprintf(stderr, "QBUF bitstream %d: %s\n", i, strerror(errno));
			goto out;
		}
	if (stream(v, CAP, 1) || stream(v, OUT, 1))
		goto out;
	for (i = 0; i < nframes; i++)
		if (qbuf(v, OUT, V4L2_MEMORY_DMABUF, i, in_fd[i], page_align(in_len), fsize)) {
			fprintf(stderr, "QBUF frame %d: %s\n", i, strerror(errno));
			goto out;
		}
	ioctl(v, VIDIOC_ENCODER_CMD, &stop);
	clock_gettime(CLOCK_MONOTONIC, &t0);
	while (got < nframes) {
		struct pollfd p = { .fd = v, .events = POLLIN };

		clock_gettime(CLOCK_MONOTONIC, &t);
		if ((t.tv_sec - t0.tv_sec) * 1000 + (t.tv_nsec - t0.tv_nsec) / 1000000 > TIMEOUT_MS) {
			fprintf(stderr, "encode timed out after %d frames\n", got);
			goto out;
		}
		if (poll(&p, 1, 200) <= 0)
			continue;
		while (!dqbuf(v, CAP, V4L2_MEMORY_DMABUF, &b, &pl)) {
			bs_used[b.index] = pl.bytesused;
			if (pl.bytesused)
				got++;
			if (b.flags & V4L2_BUF_FLAG_LAST)
				break;
		}
		while (!dqbuf(v, OUT, V4L2_MEMORY_DMABUF, &b, &pl))
			;
	}
	rc = got;
out:
	stream(v, OUT, 0);
	stream(v, CAP, 0);
	/* Unmap every buffer from the encoder's banks before the decoder maps them */
	reqbufs(v, OUT, V4L2_MEMORY_DMABUF, 0);
	reqbufs(v, CAP, V4L2_MEMORY_DMABUF, 0);
	close(v);
	for (i = 0; i < nframes; i++)
		if (in_fd[i] > 0)
			close(in_fd[i]);
	return rc;
}

static int mse_frame(struct decode *d, int fd, size_t used, int n)
{
	size_t fsize = (size_t)width * height * 3 / 2;
	uint32_t mse = 0;

	(void)used;
	if ((unsigned int)n >= raw_frames || ta_mse(raw_enc + n * fsize, (size_t)width * height, fd, &mse))
		return -1;
	memcpy(d->digest[n], &mse, sizeof(mse));
	return 0;
}

/* ---- host DMA aimed at memory the host does not own ---- */
static int write_param(const char *path, unsigned long long v)
{
	char b[32];
	int fd = open(path, O_WRONLY), n, rc;

	if (fd < 0)
		return -1;
	n = snprintf(b, sizeof(b), "%llu", v);
	rc = write(fd, b, n) == n ? 0 : -1;
	close(fd);
	return rc;
}

/* The hypervisor's probe page <name> ("data" or "pool"): address, checksum */
static int probe_read(const char *name, unsigned long long *pa, unsigned long long *sum)
{
	char line[256], n[16];
	FILE *f = fopen(GUARD, "r");
	int found = 0;

	if (!f)
		return -1;
	while (!found && fgets(line, sizeof(line), f))
		found = sscanf(line, "probe %15s pa %llx sum %llx", n, pa, sum) == 3 &&
			!strcmp(n, name);
	fclose(f);
	return found ? 0 : -1;
}

/*
 * A non-secure decode with the first page of its input (write = 0) or its
 * frames (write = 1) aimed at physical page <pa>; the shadow bank faults it
 * took in *faults.
 */
static int aimed_decode(const char *tag, unsigned long long pa, int write,
			unsigned long long *faults)
{
	struct decode d = { .cap_heap = SYS_HEAP, .frame = NULL };
	unsigned long long f0, f1, far0, far1;
	int n;

	d.nin = nau;
	guard_report(tag, &f0, &far0);
	if (write_param(AIM_WRITE, write) || write_param(AIM, pa)) {
		fprintf(stderr, "%s: cannot set %s\n", tag, AIM);
		return -1;
	}
	n = decode_run(&d);
	write_param(AIM, 0);
	write_param(AIM_WRITE, 0);
	guard_report(tag, &f1, &far1);
	close_fds(d.cap_fd, NBUF_CAP);
	*faults = f1 - f0;
	fprintf(stderr, "%s: %s aimed at %#llx: decode rc %d, %d frames, %llu shadow faults, far %#llx\n",
		tag, write ? "frames" : "input", pa, n, d.frames, *faults, far1);
	kmsg(tag);
	return 0;
}

/* Physical address of the page mapped at <va> (root: /proc/self/pagemap) */
static unsigned long long virt_to_phys(void *va)
{
	long psz = sysconf(_SC_PAGESIZE);
	uint64_t e = 0;
	int fd = open("/proc/self/pagemap", O_RDONLY);

	if (fd < 0)
		return 0;
	if (pread(fd, &e, sizeof(e), ((uintptr_t)va / psz) * sizeof(e)) != sizeof(e))
		e = 0;
	close(fd);
	if (!(e >> 63) || !(e & ((1ULL << 55) - 1)))
		return 0;
	return (e & ((1ULL << 55) - 1)) * psz;
}

/* Clean and invalidate to PoC: the next reads see what a device wrote */
static void evict(void *p, size_t len)
{
	for (size_t o = 0; o < len; o += 64)
		__asm__ volatile("dc civac, %0" : : "r"((char *)p + o) : "memory");
	__asm__ volatile("dsb sy" : : : "memory");
}

static void host_dma_cases(void)
{
	static const char *const probe[2] = { "data", "pool" };
	static const char *const read_case[2] = {
		"hyp-data-dma-read-blocked", "iommu-pool-dma-read-blocked" };
	static const char *const write_case[2] = {
		"hyp-data-dma-write-blocked", "iommu-pool-dma-write-blocked" };
	unsigned long long pa, sum0, sum1, faults, host_pa;
	long psz = sysconf(_SC_PAGESIZE);
	int i, changed = 0;
	uint8_t *host;

	if (access(AIM, W_OK) || probe_read("data", &pa, &sum0)) {
		fprintf(stderr, "no DMA aim knob or hypervisor probes\n");
		result("aimed-dma-host-page", "skip");
		for (i = 0; i < 2; i++) {
			result(read_case[i], "skip");
			result(write_case[i], "skip");
		}
		return;
	}

	/*
	 * Control: a page the host owns takes the aimed writes, unfaulted. An
	 * anonymous locked page: pagemap gives no frame for heap mmaps (PFN
	 * maps).
	 */
	host = mmap(NULL, psz, PROT_READ | PROT_WRITE,
		    MAP_PRIVATE | MAP_ANONYMOUS | MAP_POPULATE | MAP_LOCKED, -1, 0);
	if (host != MAP_FAILED) {
		memset(host, 0xa5, psz);
		evict(host, psz);
		host_pa = virt_to_phys(host);
		if (host_pa && !aimed_decode("aimed-dma-host-page", host_pa, 1, &faults)) {
			evict(host, psz);
			for (i = 0; i < psz; i++)
				changed += host[i] != 0xa5;
			fprintf(stderr, "aimed-dma-host-page: page %#llx: %d of %ld bytes written\n",
				host_pa, changed, psz);
			result("aimed-dma-host-page", !faults && changed ? "pass" : "fail");
		} else {
			fprintf(stderr, "aimed-dma-host-page: no physical address\n");
			result("aimed-dma-host-page", "fail");
		}
		munmap(host, psz);
	} else {
		result("aimed-dma-host-page", "fail");
	}

	for (i = 0; i < 2; i++) {
		int ok;

		if (probe_read(probe[i], &pa, &sum0) ||
		    aimed_decode(read_case[i], pa, 0, &faults) ||
		    probe_read(probe[i], &pa, &sum1)) {
			result(read_case[i], "fail");
			result(write_case[i], "skip");
			continue;
		}
		ok = faults > 0 && sum0 == sum1;
		fprintf(stderr, "%s: %s page %#llx sum %#llx -> %#llx\n", read_case[i],
			probe[i], pa, sum0, sum1);
		result(read_case[i], ok ? "pass" : "fail");
		if (!faults) {
			fprintf(stderr, "%s: the codec read the page: no write attempt\n",
				write_case[i]);
			result(write_case[i], "skip");
			continue;
		}
		if (aimed_decode(write_case[i], pa, 1, &faults) ||
		    probe_read(probe[i], &pa, &sum1)) {
			result(write_case[i], "fail");
			continue;
		}
		fprintf(stderr, "%s: %s page %#llx sum %#llx -> %#llx\n", write_case[i],
			probe[i], pa, sum0, sum1);
		result(write_case[i], faults > 0 && sum0 == sum1 ? "pass" : "fail");
	}
}

int main(int argc, char **argv)
{
	static struct decode ref, sec, enc_dec, neg;
	double min_psnr = argc > 2 ? atof(argv[2]) : 30.0;
	unsigned long long f0, f1, far0, far1;
	char *idx, *p, h1[65], h2[65];
	size_t len, off = 0;
	int i, ok, fd, n, refused0;

	if (argc < 2) {
		fprintf(stderr, "usage: %s <data dir> [min psnr]\n", argv[0]);
		return 1;
	}
	clip = read_file(argv[1], "clip.h264", &clip_size);
	clip_enc = read_file(argv[1], "clip.enc", &len);
	raw_enc = read_file(argv[1], "raw.enc", &raw_size);
	idx = read_file(argv[1], "clip.idx", &len);
	for (p = strtok(idx, "\n"); p && nau < MAX_AU; p = strtok(NULL, "\n")) {
		au_off[nau] = off;
		au_len[nau] = strtoul(p, NULL, 10);
		off += au_len[nau++];
	}
	p = read_file(argv[1], "raw.info", &len);
	if (sscanf(p, "%u %u %u", &width, &height, &raw_frames) != 3 || off != clip_size) {
		fprintf(stderr, "bad data dir\n");
		return 1;
	}
	if (tee_open()) {
		fprintf(stderr, "no TEE\n");
		return 1;
	}
	knob(0);
	kmsg(NULL);

	/* Reference: non-secure decode, host digests */
	ref.cap_heap = SYS_HEAP;
	ref.nin = nau;
	ref.frame = frame_sha;
	ok = !decode_run(&ref) && ref.frames > 0;
	fprintf(stderr, "ref-decode: %d frames of %zu bytes\n", ref.frames, ref.cap_len);
	result("ref-decode", ok ? "pass" : "fail");
	kmsg("ref-decode");
	close_fds(ref.cap_fd, NBUF_CAP);

	/* Secure decode: protected in, protected out, TA digests */
	sec.secure = 1;
	sec.cap_heap = PROT_HEAP;
	sec.frame = frame_ta;
	ok = !fill_protected_clip(&sec) && !decode_run(&sec) && sec.frames == ref.frames &&
	     ref.frames > 0;
	for (i = 0; ok && i < sec.frames; i++) {
		hexs(ref.digest[i], h1);
		hexs(sec.digest[i], h2);
		if (strcmp(h1, h2)) {
			fprintf(stderr, "frame %d: secure %s reference %s\n", i, h2, h1);
			ok = 0;
		}
	}
	fprintf(stderr, "secure-decode: %d frames, digests %s\n", sec.frames, ok ? "equal" : "differ");
	result("secure-decode", ok ? "pass" : "fail");
	kmsg("secure-decode");
	close_fds(sec.cap_fd, NBUF_CAP);
	close_fds(sec.ring, NBUF_OUT);

	/* Secure encode, decoded back in a secure session */
	{
		int bs_fd[MAX_AU] = { 0 };
		size_t bs_used[MAX_AU] = { 0 }, bs_size = 0;
		double worst = 1e9;

		n = raw_frames < NBUF_CAP ? raw_frames : NBUF_CAP;
		ok = encode_run(n, bs_fd, bs_used, &bs_size) == n;
		fprintf(stderr, "secure-encode: %d frames encoded\n", ok ? n : 0);
		if (ok) {
			enc_dec.secure = 1;
			enc_dec.cap_heap = PROT_HEAP;
			enc_dec.frame = mse_frame;
			enc_dec.nin = n;
			enc_dec.in_size = bs_size;
			for (i = 0; i < n; i++) {
				enc_dec.in_fd[i] = bs_fd[i];
				enc_dec.in_used[i] = bs_used[i];
			}
			ok = !decode_run(&enc_dec) && enc_dec.frames == n;
			for (i = 0; ok && i < enc_dec.frames; i++) {
				uint32_t mse;
				double psnr;

				memcpy(&mse, enc_dec.digest[i], sizeof(mse));
				psnr = mse ? 10 * log10(255.0 * 255.0 * 1000.0 / mse) : 99;
				fprintf(stderr, "frame %d: luma PSNR %.2f dB\n", i, psnr);
				if (psnr < worst)
					worst = psnr;
			}
			ok = ok && worst >= min_psnr;
		}
		result("secure-encode", ok ? "pass" : "fail");
		kmsg("secure-encode");
		close_fds(bs_fd, n);
		close_fds(enc_dec.cap_fd, NBUF_CAP);
	}

	/* Driver policy: protected buffers only in secure sessions, and back */
	neg = (struct decode){ .cap_heap = PROT_HEAP, .nin = nau, .frame = NULL };
	n = decode_run(&neg);
	result("nonsecure-protected-refused", n == -2 ? "pass" : "fail");
	kmsg("nonsecure-protected-refused");
	close_fds(neg.cap_fd, NBUF_CAP);
	neg = (struct decode){ .secure = 1, .cap_heap = SYS_HEAP, .frame = NULL };
	n = fill_protected_clip(&neg) ? -1 : decode_run(&neg);
	result("secure-unprotected-refused", n == -2 ? "pass" : "fail");
	kmsg("secure-unprotected-refused");
	close_fds(neg.cap_fd, NBUF_CAP);
	close_fds(neg.ring, NBUF_OUT);

	if (access(KNOB, W_OK)) {
		result("hyp-refuses-unlent", "skip");
		result("nonsecure-dma-blocked", "skip");
		goto done;
	}

	/*
	 * The hypervisor refuses unlent memory in a secure bank: physically
	 * contiguous (CMA heap) so that the refusal is the hypervisor's, as
	 * the kernel log line of the driver says.
	 */
	knob(1);
	refused0 = refusals();
	neg = (struct decode){ .secure = 1, .frame = NULL,
			       .cap_heap = access(CMA_HEAP, R_OK) ? SYS_HEAP : CMA_HEAP };
	n = fill_protected_clip(&neg) ? -1 : decode_run(&neg);
	{
		int refused = refusals() - refused0;

		fprintf(stderr, "hyp-refuses-unlent: %s, decode rc %d, %d hypervisor refusals logged\n",
			neg.cap_heap, n, refused);
		result("hyp-refuses-unlent", n == -2 && refused > 0 ? "pass" : "fail");
		kmsg("hyp-refuses-unlent");
	}
	close_fds(neg.cap_fd, NBUF_CAP);
	close_fds(neg.ring, NBUF_OUT);

	/*
	 * A non-secure decode into protected buffers the TA filled with the
	 * encrypted raw frames' plaintext: the shadow stage 2 must fault the
	 * codec's writes and the TA must find every buffer unchanged.
	 */
	fprintf(stderr, "nonsecure-dma-blocked: start\n");
	guard_report("before", &f0, &far0);
	neg = (struct decode){ .cap_heap = PROT_HEAP, .nin = nau, .prefill = 1 };
	n = decode_run(&neg);
	guard_report("after", &f1, &far1);
	ok = f1 > f0;
	for (i = 0, fd = 0; i < NBUF_CAP; i++) {
		uint32_t diff = ~0u;

		if (neg.cap_fd[i] <= 0)
			continue;
		fd++;
		if (ta_check(raw_enc, (size_t)width * height * 3 / 2, neg.cap_fd[i], &diff) ||
		    diff) {
			fprintf(stderr, "capture %d: %u lines differ from the TA's data\n", i, diff);
			ok = 0;
		}
	}
	ok = ok && fd == NBUF_CAP;
	fprintf(stderr, "nonsecure-dma-blocked: decode rc %d, shadow faults %llu -> %llu, far %#llx\n",
		n, f0, f1, far1);
	/*
	 * The SMMU terminates the faulting writes and the firmware may still
	 * report the frames done: the decode's outcome proves nothing, the
	 * fault record and the unchanged buffers do.
	 */
	result("nonsecure-dma-blocked", ok ? "pass" : "fail");
	kmsg("nonsecure-dma-blocked");
	close_fds(neg.cap_fd, NBUF_CAP);
	knob(0);
done:
	host_dma_cases();
	return 0;
}
