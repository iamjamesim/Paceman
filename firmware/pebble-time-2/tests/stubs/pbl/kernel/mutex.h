/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#define PBL_MUTEX_DEFINE(name) struct pbl_mutex name
#define PBL_FOREVER            1
#define PBL_NO_WAIT            0
struct pbl_mutex {
  int held;
};
int pbl_mutex_lock(struct pbl_mutex *, int);
void pbl_mutex_unlock(struct pbl_mutex *);
