/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <stddef.h>
#include <stdint.h>
#define PBL_CRC32_RESIDUE 0x2144df1cu
uint32_t pbl_crc32(uint32_t, const void *, size_t);
