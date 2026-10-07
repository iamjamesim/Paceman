/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <stdbool.h>
bool system_task_add_callback_droppable(void (*)(void *), void *);
