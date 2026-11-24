// The worker and the signed Guardian share the original, per-lease Host pipe.
// Only measured geometry crosses it here. The Host still owns the final switch.
#pragma once
#include "../../../include/nearpane_window_engine.h"

int np_corner_copy_measurement_writer(int fd);
bool np_corner_send_measurement(int fd, const NPRequest *request, NPRect frame, uint32_t owned);
