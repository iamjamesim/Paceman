/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <pbl/services/filesystem/pfs.h>
typedef struct {
  int unused;
} SettingsFile;
int settings_file_open(SettingsFile *, const char *, int);
void settings_file_close(SettingsFile *);
int settings_file_get_len(SettingsFile *, const void *, size_t);
int settings_file_get(SettingsFile *, const void *, size_t, void *, size_t);
int settings_file_set(SettingsFile *, const void *, size_t, const void *, size_t);
