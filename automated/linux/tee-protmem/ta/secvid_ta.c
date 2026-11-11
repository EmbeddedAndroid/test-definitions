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

/*
 * Protected buffers are cacheable in the TA and the codec reads and writes
 * them without snooping: push what the TA wrote to memory, and drop stale
 * lines before reading what a device wrote.
 */
static TEE_Result sync_for_device(void *buf, size_t len)
{
	return TEE_CacheFlush(buf, len);
}

static TEE_Result sync_for_cpu(void *buf, size_t len)
{
	return TEE_CacheInvalidate(buf, len);
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
	res = sync_for_device(p[1].memref.buffer, p[1].memref.size);
	if (res)
		goto out;
	res = digest_frames(p[1].memref.buffer, p[3].value.a, p[3].value.b,
			    &p[2]);
out:
	TEE_FreeTransientObject(key);
	TEE_FreeOperation(op);
	return res;
}

#define LINE		64
#define CHECK_CHUNK	4096

static TEE_Result cmd_check(uint32_t types, TEE_Param p[TEE_NUM_PARAMS])
{
	const uint8_t *prot = p[1].memref.buffer;
	TEE_OperationHandle op = TEE_HANDLE_NULL;
	TEE_ObjectHandle key = TEE_HANDLE_NULL;
	uint32_t diff = 0, zero = 0, first = UINT32_MAX;
	TEE_Attribute attr = { };
	TEE_Result res = TEE_SUCCESS;
	size_t off = 0, len = 0, i = 0, k = 0;
	uint8_t *plain = NULL;

	if (types != TEE_PARAM_TYPES(TEE_PARAM_TYPE_MEMREF_INPUT,
				     TEE_PARAM_TYPE_MEMREF_INPUT,
				     TEE_PARAM_TYPE_VALUE_OUTPUT,
				     TEE_PARAM_TYPE_VALUE_OUTPUT))
		return TEE_ERROR_BAD_PARAMETERS;
	len = p[1].memref.size;
	if (!len || len % CHECK_CHUNK || p[0].memref.size != len)
		return TEE_ERROR_BAD_PARAMETERS;
	if (TEE_CheckMemoryAccessRights(TEE_MEMORY_ACCESS_READ |
					TEE_MEMORY_ACCESS_SECURE |
					TEE_MEMORY_ACCESS_ANY_OWNER,
					p[1].memref.buffer, len))
		return TEE_ERROR_SECURITY;
	res = sync_for_cpu(p[1].memref.buffer, len);
	if (res)
		return res;

	plain = TEE_Malloc(CHECK_CHUNK, TEE_MALLOC_FILL_ZERO);
	if (!plain)
		return TEE_ERROR_OUT_OF_MEMORY;
	res = TEE_AllocateOperation(&op, TEE_ALG_AES_CTR, TEE_MODE_DECRYPT, 128);
	if (res)
		goto out;
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
	for (off = 0; off < len && !res; off += CHECK_CHUNK) {
		size_t olen = CHECK_CHUNK;

		res = TEE_CipherUpdate(op, (const uint8_t *)p[0].memref.buffer +
				       off, CHECK_CHUNK, plain, &olen);
		if (res || olen != CHECK_CHUNK) {
			res = res ? res : TEE_ERROR_GENERIC;
			break;
		}
		for (i = 0; i < CHECK_CHUNK; i += LINE) {
			if (!TEE_MemCompare(prot + off + i, plain + i, LINE))
				continue;
			diff++;
			if (first == UINT32_MAX)
				first = off + i;
			for (k = 0; k < LINE && !prot[off + i + k]; k++)
				;
			if (k == LINE)
				zero++;
		}
	}
	p[2].value.a = diff;
	p[2].value.b = zero;
	p[3].value.a = first;
	p[3].value.b = len / LINE;
out:
	TEE_Free(plain);
	TEE_FreeTransientObject(key);
	TEE_FreeOperation(op);
	return res;
}

static TEE_Result cmd_mse(uint32_t types, TEE_Param p[TEE_NUM_PARAMS])
{
	const uint8_t *dec = p[1].memref.buffer;
	TEE_OperationHandle op = TEE_HANDLE_NULL;
	TEE_ObjectHandle key = TEE_HANDLE_NULL;
	TEE_Attribute attr = { };
	TEE_Result res = TEE_SUCCESS;
	size_t len = 0, olen = 0, i = 0;
	uint8_t *plain = NULL;
	uint64_t sse = 0;

	if (types != TEE_PARAM_TYPES(TEE_PARAM_TYPE_MEMREF_INPUT,
				     TEE_PARAM_TYPE_MEMREF_INPUT,
				     TEE_PARAM_TYPE_VALUE_OUTPUT,
				     TEE_PARAM_TYPE_VALUE_INPUT))
		return TEE_ERROR_BAD_PARAMETERS;
	len = p[3].value.a;
	if (!len || p[0].memref.size < len || p[1].memref.size < len)
		return TEE_ERROR_BAD_PARAMETERS;
	if (TEE_CheckMemoryAccessRights(TEE_MEMORY_ACCESS_READ |
					TEE_MEMORY_ACCESS_SECURE |
					TEE_MEMORY_ACCESS_ANY_OWNER,
					p[1].memref.buffer, len))
		return TEE_ERROR_SECURITY;
	res = sync_for_cpu(p[1].memref.buffer, len);
	if (res)
		return res;

	plain = TEE_Malloc(len, TEE_MALLOC_FILL_ZERO);
	if (!plain)
		return TEE_ERROR_OUT_OF_MEMORY;
	res = TEE_AllocateOperation(&op, TEE_ALG_AES_CTR, TEE_MODE_DECRYPT, 128);
	if (res)
		goto out;
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
	olen = len;
	res = TEE_CipherDoFinal(op, p[0].memref.buffer, len, plain, &olen);
	if (res)
		goto out;
	for (i = 0; i < len; i++) {
		int d = (int)dec[i] - (int)plain[i];

		sse += (uint64_t)(d * d);
	}
	p[2].value.a = (uint32_t)(sse * 1000 / len);
	p[2].value.b = len;
out:
	TEE_Free(plain);
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
	res = sync_for_cpu(p[0].memref.buffer, p[0].memref.size);
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
	case SECVID_CMD_CHECK:
		return cmd_check(types, p);
	case SECVID_CMD_MSE:
		return cmd_mse(types, p);
	default:
		return TEE_ERROR_NOT_SUPPORTED;
	}
}
