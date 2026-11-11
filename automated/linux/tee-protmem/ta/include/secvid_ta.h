/* SPDX-License-Identifier: BSD-2-Clause */
/*
 * Copyright (c) 2026 Qualcomm Technologies, Inc. and/or its subsidiaries.
 */
#ifndef SECVID_TA_H
#define SECVID_TA_H

#define SECVID_TA_UUID { 0x1b7d45ae, 0x0f97, 0x4ee8, \
	{ 0xbd, 0xeb, 0xf0, 0x5a, 0x85, 0x2d, 0xe1, 0x80 } }

/*
 * Decrypt an AES-128-CTR stream of <frames> frames of <frame size> bytes
 * into a protected (secure) buffer and return the SHA-256 of each
 * decrypted frame. Refused with TEE_ERROR_SECURITY when the output is not
 * secure memory.
 *
 * [in]  memref  ciphertext (non-secure)
 * [out] memref  plaintext (secure)
 * [out] memref  frames * 32 bytes of SHA-256
 * [in]  value   a: frame size, b: frames
 */
#define SECVID_CMD_DECRYPT	0

/*
 * SHA-256 of each frame of a secure buffer.
 *
 * [in]  memref  frames (secure)
 * [out] memref  frames * 32 bytes of SHA-256
 * [in]  value   a: frame size, b: frames
 */
#define SECVID_CMD_DIGEST	1

/*
 * [in] ciphertext, [in] protected buffer, [out] value a: 64-byte lines
 * that differ from the plaintext, b: how many of those are all zero,
 * [out] value a: offset of the first differing line (~0 if none),
 * b: lines compared. Says how the buffer differs, never what it holds.
 */
#define SECVID_CMD_CHECK	2

/*
 * Mean squared error, in thousandths, between the first <len> bytes of a
 * secure buffer (a decoded frame's luma) and the same bytes of a
 * ciphertext decrypted inside the TA (the source frame): says how close
 * a secure encode and decode came, never what the frames hold.
 *
 * [in]  memref  ciphertext of the source frame (non-secure)
 * [in]  memref  decoded frame (secure)
 * [out] value   a: MSE * 1000, b: bytes compared
 * [in]  value   a: len
 */
#define SECVID_CMD_MSE		3

#endif
