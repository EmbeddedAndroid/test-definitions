// SPDX-License-Identifier: GPL-2.0-only
/*
 * Copyright (c) 2026 Qualcomm Technologies, Inc. and/or its subsidiaries.
 *
 * pvm-probe [-p]: a minimal VMM that runs pvm-probe-guest.S in
 * a normal VM, or with -p a protected VM (KVM_VM_TYPE_ARM_PROTECTED), and
 * reports what the host and the guest can see of each other:
 *
 *   host-read     the VMM reads the guest's secret through its own
 *                 mapping: visible in a normal VM, SIGSEGV (SEGV_ACCERR)
 *                 in a protected VM;
 *   guest-intact  after that read the guest recomputes its checksum and
 *                 the VMM checks it: the guest ran on, data unchanged;
 *   secure-ipa    a guest load from the IPA equal to the OP-TEE carve-out
 *                 PA is backed by nothing: it exits to the VMM as MMIO and
 *                 gets the VMM's value (the guest only reaches memory its
 *                 VMM gave it; this does not probe the carve-out itself);
 *   ffa-hvc       FFA_VERSION over HVC is not supported;
 *   smc           a normal VM's SMC returns NOT_SUPPORTED, a protected
 *                 VM's SMC is an undefined instruction (ESR EC 0x0).
 *
 * Output: one "<case> <pass|fail>" line per case on stdout (sh-test-lib
 * format, prefixed by the mode), details on stderr. Exit 0 when every case
 * ran, 1 on a setup error.
 */
#include <errno.h>
#include <fcntl.h>
#include <setjmp.h>
#include <stddef.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <linux/kvm.h>

#ifndef KVM_VM_TYPE_ARM_PROTECTED
#define KVM_VM_TYPE_ARM_PROTECTED	(1UL << 31)
#endif

#define GUEST_BASE	0x80000000UL
#define GUEST_SIZE	0x200000UL
#define DB		0x10000000UL
#define SECURE_IPA	0xf7c00000UL
#define SECRET_WORDS	1024
#define SMCCC_NOT_SUPPORTED	0xffffffffffffffffULL

extern const char pvm_guest_start[], pvm_guest_end[];

static const char *mode;
static sigjmp_buf segv_jmp;
static volatile sig_atomic_t segv_code;

static void segv(int sig, siginfo_t *si, void *uc)
{
	(void)sig;
	(void)uc;
	segv_code = si->si_code;
	siglongjmp(segv_jmp, 1);
}

static void result(const char *name, int pass)
{
	printf("%s-%s %s\n", mode, name, pass ? "pass" : "fail");
	fflush(stdout);
}

/* Read *p; 0 on success, -1 on SIGSEGV (segv_code holds its si_code). */
static int guarded_read(volatile uint64_t *p, uint64_t *val)
{
	struct sigaction sa;
	int ret = 0;

	memset(&sa, 0, sizeof(sa));
	sa.sa_sigaction = segv;
	sa.sa_flags = SA_SIGINFO;
	sigaction(SIGSEGV, &sa, NULL);
	segv_code = 0;
	if (!sigsetjmp(segv_jmp, 1))
		*val = *p;
	else
		ret = -1;
	signal(SIGSEGV, SIG_DFL);
	return ret;
}

static uint64_t reg_id_core(unsigned int off)
{
	return KVM_REG_ARM64 | KVM_REG_SIZE_U64 | KVM_REG_ARM_CORE | off;
}

static int set_reg(int vcpu, uint64_t id, uint64_t val)
{
	struct kvm_one_reg r = { .id = id, .addr = (uintptr_t)&val };

	return ioctl(vcpu, KVM_SET_ONE_REG, &r);
}

static uint64_t secret_sum(uint64_t nonce, uint64_t *first)
{
	uint64_t x = nonce, sum = 0;

	for (int i = 0; i < SECRET_WORDS; i++) {
		x = x * 6364136223846793005ULL + 1442695040888963407ULL;
		if (!i)
			*first = x;
		sum = x ^ ((sum >> 13) | (sum << 51));
	}
	return sum;
}

/* Run until the guest writes the doorbell; returns the offset or -1. */
static long run_to_db(int vcpu, struct kvm_run *run, uint64_t *val)
{
	for (;;) {
		if (ioctl(vcpu, KVM_RUN, 0)) {
			fprintf(stderr, "%s: KVM_RUN: %s\n", mode, strerror(errno));
			return -1;
		}
		if (run->exit_reason != KVM_EXIT_MMIO) {
			fprintf(stderr, "%s: exit reason %u\n", mode, run->exit_reason);
			return -1;
		}
		if (!run->mmio.is_write) {
			fprintf(stderr, "%s: guest MMIO read at 0x%llx, len %u\n", mode,
				(unsigned long long)run->mmio.phys_addr, run->mmio.len);
			if (run->mmio.phys_addr != SECURE_IPA)
				return -1;
			/* What the VMM chooses to return, not memory. */
			memset(run->mmio.data, 0x5a, sizeof(run->mmio.data));
			continue;
		}
		if (run->mmio.phys_addr < DB || run->mmio.phys_addr >= DB + 0x1000) {
			fprintf(stderr, "%s: guest MMIO write at 0x%llx\n", mode,
				(unsigned long long)run->mmio.phys_addr);
			return -1;
		}
		memcpy(val, run->mmio.data, sizeof(*val));
		return run->mmio.phys_addr - DB;
	}
}

int main(int argc, char **argv)
{
	uint64_t nonce = 0, val, first, sum, esr = 0, smc_ret = 0, ffa_ret = 0, sec = 0;
	int protected = 0, opt, kvm, vm, vcpu, have_esr = 0, have_smc = 0, done = 0;
	struct kvm_vcpu_init init;
	struct kvm_run *run;
	size_t len = pvm_guest_end - pvm_guest_start;
	char *mem;
	long off;

	while ((opt = getopt(argc, argv, "p")) != -1) {
		switch (opt) {
		case 'p':
			protected = 1;
			break;
		default:
			fprintf(stderr, "usage: %s [-p]\n", argv[0]);
			return 1;
		}
	}
	mode = protected ? "pvm" : "npvm";
	nonce = (uint64_t)time(NULL) * 2654435761ULL ^ getpid();

	kvm = open("/dev/kvm", O_RDWR | O_CLOEXEC);
	if (kvm < 0) {
		perror("/dev/kvm");
		return 1;
	}
	vm = ioctl(kvm, KVM_CREATE_VM, protected ? KVM_VM_TYPE_ARM_PROTECTED : 0UL);
	if (vm < 0) {
		fprintf(stderr, "%s: KVM_CREATE_VM: %s\n", mode, strerror(errno));
		result("create", 0);
		return 1;
	}
	result("create", 1);

	mem = mmap(NULL, GUEST_SIZE, PROT_READ | PROT_WRITE,
		   MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
	if (mem == MAP_FAILED || len > GUEST_SIZE) {
		perror("guest memory");
		return 1;
	}
	memcpy(mem, pvm_guest_start, len);
	struct kvm_userspace_memory_region slot = {
		.slot = 0, .guest_phys_addr = GUEST_BASE,
		.memory_size = GUEST_SIZE, .userspace_addr = (uintptr_t)mem,
	};
	if (ioctl(vm, KVM_SET_USER_MEMORY_REGION, &slot)) {
		perror("KVM_SET_USER_MEMORY_REGION");
		return 1;
	}

	vcpu = ioctl(vm, KVM_CREATE_VCPU, 0);
	if (vcpu < 0 || ioctl(vm, KVM_ARM_PREFERRED_TARGET, &init)) {
		perror("vcpu");
		return 1;
	}
	/* pKVM refuses a protected vCPU without PSCI 0.2; same for both modes. */
	init.features[0] |= 1U << KVM_ARM_VCPU_PSCI_0_2;
	if (ioctl(vcpu, KVM_ARM_VCPU_INIT, &init)) {
		perror("KVM_ARM_VCPU_INIT");
		return 1;
	}
	if (set_reg(vcpu, reg_id_core(KVM_REG_ARM_CORE_REG(regs.pc)), GUEST_BASE) ||
	    set_reg(vcpu, reg_id_core(KVM_REG_ARM_CORE_REG(regs.regs[0])), nonce)) {
		perror("KVM_SET_ONE_REG");
		return 1;
	}
	run = mmap(NULL, ioctl(kvm, KVM_GET_VCPU_MMAP_SIZE, 0), PROT_READ | PROT_WRITE,
		   MAP_SHARED, vcpu, 0);
	if (run == MAP_FAILED) {
		perror("kvm_run");
		return 1;
	}

	sum = secret_sum(nonce, &first);
	off = run_to_db(vcpu, run, &val);
	result("guest-ready", off == 0 && val == 1);
	if (off != 0)
		return 1;

	/* The secret starts one page into the image (see the .S layout). */
	volatile uint64_t *secret = (uint64_t *)(mem + ((len - SECRET_WORDS * 8) & ~0xfffUL));
	if (!guarded_read(secret, &val)) {
		fprintf(stderr, "%s: host read 0x%016llx (guest wrote 0x%016llx)\n", mode,
			(unsigned long long)val, (unsigned long long)first);
		result("host-read", !protected && val == first);
	} else {
		fprintf(stderr, "%s: host read: SIGSEGV si_code %d (SEGV_ACCERR %d)\n",
			mode, (int)segv_code, SEGV_ACCERR);
		result("host-read", protected && segv_code == SEGV_ACCERR);
	}

	while (!done) {
		off = run_to_db(vcpu, run, &val);
		switch (off) {
		case 0x08:
			fprintf(stderr, "%s: guest sum 0x%016llx, expected 0x%016llx\n", mode,
				(unsigned long long)val, (unsigned long long)sum);
			result("guest-intact", val == sum);
			break;
		case 0x10:
			sec = val;
			break;
		case 0x18:
			ffa_ret = val;
			break;
		case 0x20:
			smc_ret = val;
			have_smc = 1;
			break;
		case 0x28:
			esr = val;
			have_esr = 1;
			break;
		case 0x30:
			done = 1;
			break;
		default:
			result("guest-done", 0);
			return 1;
		}
	}
	result("guest-done", 1);
	fprintf(stderr, "%s: secure IPA load 0x%016llx, FFA_VERSION hvc 0x%llx\n", mode,
		(unsigned long long)sec, (unsigned long long)ffa_ret);
	result("secure-ipa", sec == 0x5a5a5a5a5a5a5a5aULL);
	result("ffa-hvc", ffa_ret == SMCCC_NOT_SUPPORTED);
	fprintf(stderr, "%s: smc %s 0x%llx, esr %s 0x%llx\n", mode,
		have_smc ? "returned" : "did not return", (unsigned long long)smc_ret,
		have_esr ? "taken" : "none", (unsigned long long)esr);
	if (protected)
		result("smc", have_esr && (esr >> 26) == 0);
	else
		result("smc", !have_esr && smc_ret == SMCCC_NOT_SUPPORTED);
	return 0;
}
