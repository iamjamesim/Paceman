/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
typedef struct {
  int unused;
} VibeScore;
#define VibeClient_Notifications 0
VibeScore *vibe_client_get_score(int);
void vibe_score_do_vibe(VibeScore *);
void vibe_score_destroy(VibeScore *);
