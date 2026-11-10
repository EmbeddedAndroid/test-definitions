/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Copyright (c) 2026 Qualcomm Technologies, Inc. and/or its subsidiaries.
 *
 * Guest of pvm-probe: runs at EL1 with the MMU off from GUEST_BASE and
 * talks to the VMM only through MMIO exits to the doorbell page, which is
 * outside the guest's memory slot. x0 holds the nonce on entry.
 *
 *   DB+0x00 write 1          secret written, VMM may probe it
 *   DB+0x08 write sum        checksum of the secret, read back by the guest
 *   DB+0x10 write value      what a load from SECURE_IPA returned
 *   DB+0x18 write x0         FFA_VERSION over HVC
 *   DB+0x20 write x0         FFA_VERSION over SMC (when the SMC returns)
 *   DB+0x28 write esr        an exception the guest took (ESR_EL1)
 *   DB+0x30 write 0          done
 */

#define DB		0x10000000
#define SECURE_IPA	0xf7c00000
#define SECRET_WORDS	1024
#define FFA_VERSION	0x84000063
#define FFA_V1_1	0x00010001

	/* Copied to GUEST_BASE as is: page aligned, so the secret is too. */
	.section .rodata.pvm_guest, "a"
	.global	pvm_guest_start, pvm_guest_end
	.balign	4096

pvm_guest_start:
	ldr	x9, =DB
	adr	x6, vectors
	msr	vbar_el1, x6
	isb

	/* Fill the secret: an LCG seeded with the nonce. */
	ldr	x10, =6364136223846793005
	ldr	x11, =1442695040888963407
	mov	x3, x0
	adr	x1, secret
	mov	x2, #SECRET_WORDS
1:	madd	x3, x3, x10, x11
	str	x3, [x1], #8
	subs	x2, x2, #1
	b.ne	1b
	mov	x0, #1
	str	x0, [x9]

	/* The VMM has had its look; prove the secret is intact. */
	adr	x1, secret
	mov	x2, #SECRET_WORDS
	mov	x4, #0
2:	ldr	x5, [x1], #8
	eor	x4, x5, x4, ror #13
	subs	x2, x2, #1
	b.ne	2b
	str	x4, [x9, #0x08]

	/* Secure world memory is not mapped: the load is an MMIO exit. */
	ldr	x10, =SECURE_IPA
	ldr	x5, [x10]
	str	x5, [x9, #0x10]

	ldr	w0, =FFA_VERSION
	ldr	w1, =FFA_V1_1
	hvc	#0
	str	x0, [x9, #0x18]

	ldr	w0, =FFA_VERSION
	ldr	w1, =FFA_V1_1
	smc	#0
	str	x0, [x9, #0x20]

	str	xzr, [x9, #0x30]
3:	wfi
	b	3b

	.ltorg

	/* EL1h synchronous exceptions: report ESR_EL1, skip the instruction. */
	.balign	2048
vectors:
	.skip	0x200
	mrs	x7, esr_el1
	str	x7, [x9, #0x28]
	mrs	x8, elr_el1
	add	x8, x8, #4
	msr	elr_el1, x8
	eret
	.balign	2048, 0

	.balign	4096, 0
secret:
	.skip	SECRET_WORDS * 8
pvm_guest_end:
