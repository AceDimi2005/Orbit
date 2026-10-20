#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Swift cannot define C variadic functions, so this tiny bridge formats the library's
// log messages and forwards them to a plain callback.
typedef void (*OrbitMoonlightLogSink)(const char* message);
void OrbitMoonlightSetLogSink(OrbitMoonlightLogSink sink);
void OrbitMoonlightLogMessage(const char* format, ...);

#ifdef __cplusplus
}
#endif

#include "Limelight.h"

#ifdef __cplusplus
extern "C" {
#endif
// Points the library's variadic log callback at the bridge above.
void OrbitMoonlightInstallLogCallback(PCONNECTION_LISTENER_CALLBACKS callbacks);
#ifdef __cplusplus
}
#endif
