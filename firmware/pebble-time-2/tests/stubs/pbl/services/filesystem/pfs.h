/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#define S_SUCCESS        0
#define E_DOES_NOT_EXIST (-1)
#define E_UNKNOWN        (-2)
#define OP_FLAG_READ     1
#define OP_FLAG_WRITE    2
#define FILE_TYPE_STATIC 0xfe
int pfs_open(const char *, uint8_t, uint8_t, size_t);
int pfs_close(int);
int pfs_read(int, void *, size_t);
int pfs_write(int, const void *, size_t);
size_t pfs_get_file_size(int);
