#include "OrbitMoonlightBridge.h"

#include <stdarg.h>
#include <stdio.h>

static OrbitMoonlightLogSink gLogSink = NULL;

void OrbitMoonlightSetLogSink(OrbitMoonlightLogSink sink) {
    gLogSink = sink;
}

void OrbitMoonlightLogMessage(const char* format, ...) {
    OrbitMoonlightLogSink sink = gLogSink;
    if (sink == NULL || format == NULL) {
        return;
    }
    char buffer[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    sink(buffer);
}

void OrbitMoonlightInstallLogCallback(PCONNECTION_LISTENER_CALLBACKS callbacks) {
    if (callbacks != NULL) {
        callbacks->logMessage = OrbitMoonlightLogMessage;
    }
}
