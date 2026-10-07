/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include "paceman_state.h"

PacemanStorage paceman_storage_load(PacemanRecord *record);
bool paceman_storage_save(const PacemanRecord *record, bool create);
