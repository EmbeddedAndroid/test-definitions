/* SPDX-License-Identifier: BSD-2-Clause */
/*
 * Copyright (c) 2026 Qualcomm Technologies, Inc. and/or its subsidiaries.
 */
#ifndef USER_TA_HEADER_DEFINES_H
#define USER_TA_HEADER_DEFINES_H

#include <secvid_ta.h>

#define TA_UUID			SECVID_TA_UUID
#define TA_FLAGS		(TA_FLAG_SINGLE_INSTANCE | TA_FLAG_MULTI_SESSION | \
				 TA_FLAG_SECURE_DATA_PATH)
#define TA_STACK_SIZE		(8 * 1024)
#define TA_DATA_SIZE		(512 * 1024)

#endif
