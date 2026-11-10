// SPDX-License-Identifier: BSD-2-Clause
/*
 * Copyright (c) 2026 Qualcomm Technologies, Inc. and/or its subsidiaries.
 *
 * Secure video stand-in for tee-protmem: decrypts a stream into a
 * protected buffer and reports only per-frame digests, as a DRM TA feeding
 * a secure decoder would. The key is a test key (../stream-key.txt).
 */
#include <string.h>
#include <tee_internal_api.h>
#include <tee_internal_api_extensions.h>

#include <secvid_ta.h>

static const uint8_t stream_key[16] = {
	0x5d, 0xaa, 0x82, 0x2d, 0x6c, 0x0e, 0xec, 0xd9, 0xe5, 0x80, 0xab, 0x8b, 0x95, 0xab, 0x3f, 0x80
};

static const uint8_t stream_iv[16] = {
	0x1b, 0x78, 0x2a, 0xd1, 0xe4, 0x5f, 0x0b, 0x5d, 0xf4, 0xff, 0x9f, 0xde, 0xaa, 0x6a, 0x09, 0xdf
};

#define SHA256_SIZE	32

static TEE_Result digest_frames(const uint8_t *buf, uint32_t frame_size,
				uint32_t frames, TEE_Param *out)
{
	TEE_OperationHandle op = TEE_HANDLE_NULL;
	TEE_Result res = TEE_SUCCESS;
	uint32_t n = 0;

	if (out->memref.size < (size_t)frames * SHA256_SIZE)
		return TEE_ERROR_SHORT_BUFFER;
	res = TEE_AllocateOperation(&op, TEE_ALG_SHA256, TEE_MODE_DIGEST, 0);
	if (res)
		return res;
	for (n = 0; n < frames && !res; n++) {
		size_t len = SHA256_SIZE;

		res = TEE_DigestDoFinal(op, buf + (size_t)n * frame_size,
					frame_size,
					(uint8_t *)out->memref.buffer +
					n * SHA256_SIZE, &len);
	}
	TEE_FreeOperation(op);
	out->memref.size = (size_t)frames * SHA256_SIZE;
	return res;
}

static TEE_Result check_frames(TEE_Param *p, TEE_Param *v, uint32_t access)
{
	size_t len = (size_t)v->value.a * v->value.b;

	if (!v->value.a || !v->value.b || p->memref.size != len)
		return TEE_ERROR_BAD_PARAMETERS;
	/* Plaintext frames only ever live in secure memory. */
	if (TEE_CheckMemoryAccessRights(access | TEE_MEMORY_ACCESS_SECURE |
					TEE_MEMORY_ACCESS_ANY_OWNER,
					p->memref.buffer, len))
		return TEE_ERROR_SECURITY;
	return TEE_SUCCESS;
}

static TEE_Result cmd_decrypt(uint32_t types, TEE_Param p[TEE_NUM_PARAMS])
{
	TEE_OperationHandle op = TEE_HANDLE_NULL;
	TEE_ObjectHandle key = TEE_HANDLE_NULL;
	TEE_Attribute attr = { };
	TEE_Result res = TEE_SUCCESS;
	size_t len = 0;

	if (types != TEE_PARAM_TYPES(TEE_PARAM_TYPE_MEMREF_INPUT,
				     TEE_PARAM_TYPE_MEMREF_OUTPUT,
				     TEE_PARAM_TYPE_MEMREF_OUTPUT,
				     TEE_PARAM_TYPE_VALUE_INPUT))
		return TEE_ERROR_BAD_PARAMETERS;
	res = check_frames(&p[1], &p[3], TEE_MEMORY_ACCESS_WRITE);
	if (res)
		return res;
	if (p[0].memref.size != p[1].memref.size)
		return TEE_ERROR_BAD_PARAMETERS;

	res = TEE_AllocateOperation(&op, TEE_ALG_AES_CTR, TEE_MODE_DECRYPT, 128);
	if (res)
		return res;
	res = TEE_AllocateTransientObject(TEE_TYPE_AES, 128, &key);
	if (res)
		goto out;
	TEE_InitRefAttribute(&attr, TEE_ATTR_SECRET_VALUE, stream_key,
			     sizeof(stream_key));
	res = TEE_PopulateTransientObject(key, &attr, 1);
	if (res)
		goto out;
	res = TEE_SetOperationKey(op, key);
	if (res)
		goto out;
	TEE_CipherInit(op, stream_iv, sizeof(stream_iv));
	len = p[1].memref.size;
	res = TEE_CipherDoFinal(op, p[0].memref.buffer, p[0].memref.size,
				p[1].memref.buffer, &len);
	if (res)
		goto out;
	res = digest_frames(p[1].memref.buffer, p[3].value.a, p[3].value.b,
			    &p[2]);
out:
	TEE_FreeTransientObject(key);
	TEE_FreeOperation(op);
	return res;
}

static TEE_Result cmd_digest(uint32_t types, TEE_Param p[TEE_NUM_PARAMS])
{
	TEE_Result res = TEE_SUCCESS;

	if (types != TEE_PARAM_TYPES(TEE_PARAM_TYPE_MEMREF_INPUT,
				     TEE_PARAM_TYPE_MEMREF_OUTPUT,
				     TEE_PARAM_TYPE_VALUE_INPUT,
				     TEE_PARAM_TYPE_NONE))
		return TEE_ERROR_BAD_PARAMETERS;
	res = check_frames(&p[0], &p[2], TEE_MEMORY_ACCESS_READ);
	if (res)
		return res;
	return digest_frames(p[0].memref.buffer, p[2].value.a, p[2].value.b,
			     &p[1]);
}

TEE_Result TA_CreateEntryPoint(void)
{
	return TEE_SUCCESS;
}

void TA_DestroyEntryPoint(void)
{
}

TEE_Result TA_OpenSessionEntryPoint(uint32_t types __unused,
				    TEE_Param p[TEE_NUM_PARAMS] __unused,
				    void **ctx __unused)
{
	return TEE_SUCCESS;
}

void TA_CloseSessionEntryPoint(void *ctx __unused)
{
}

TEE_Result TA_InvokeCommandEntryPoint(void *ctx __unused, uint32_t cmd,
				      uint32_t types,
				      TEE_Param p[TEE_NUM_PARAMS])
{
	switch (cmd) {
	case SECVID_CMD_DECRYPT:
		return cmd_decrypt(types, p);
	case SECVID_CMD_DIGEST:
		return cmd_digest(types, p);
	default:
		return TEE_ERROR_NOT_SUPPORTED;
	}
}
