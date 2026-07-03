#ifndef AFFECTIVE_CORE_SESSION_H
#define AFFECTIVE_CORE_SESSION_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Minimal in-process BSP boot shim. It starts a localhost Brain Session
// Protocol runtime and returns the bound loopback TCP port. Hosts should then
// communicate exclusively via BSP NDJSON over TCP.
int32_t affective_session_start(const char *config_json);
void affective_session_stop(void);

#ifdef __cplusplus
}
#endif

#endif
