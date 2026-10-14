#include "TemperatureBridge.h"
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

// AppleSMC's private wire layout and read opcodes, cross-checked against:
// https://github.com/exelban/stats/blob/master/SMC/smc.swift
// This bridge implements only key metadata (9) and byte reads (5), never writes.
typedef struct {
    uint32_t key;
    uint8_t version[6];
    uint8_t alignment[2];
    uint8_t powerLimits[16];
    struct { uint32_t size, type; uint8_t attributes; } info;
    uint8_t result, status, operation;
    uint32_t data;
    uint8_t bytes[32];
} SLWire;
_Static_assert(sizeof(SLWire) == 80, "AppleSMC message size");
_Static_assert(offsetof(SLWire, info) == 28, "AppleSMC key info offset");
_Static_assert(offsetof(SLWire, bytes) == 48, "AppleSMC data offset");

struct SLTemperatureConnection {
    io_connect_t port;
    struct { uint32_t key, size, type; } cache[32];
    unsigned count;
};

static uint32_t keyCode(const char *s) {
    return (uint32_t)(uint8_t)s[0] << 24 | (uint32_t)(uint8_t)s[1] << 16 |
           (uint32_t)(uint8_t)s[2] << 8 | (uint8_t)s[3];
}

static bool readMessage(SLTemperatureConnection *c, SLWire *request, SLWire *reply) {
    size_t length = sizeof(*reply);
    memset(reply, 0, length);
    return IOConnectCallStructMethod(c->port, 2, request, sizeof(*request), reply, &length) == KERN_SUCCESS &&
           length == sizeof(*reply) && reply->result == 0;
}

SLTemperatureConnection *SLTemperatureOpen(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return NULL;
    io_connect_t port = 0;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &port);
    IOObjectRelease(service);
    if (result != KERN_SUCCESS) return NULL;
    SLTemperatureConnection *c = calloc(1, sizeof(*c));
    if (!c) { IOServiceClose(port); return NULL; }
    c->port = port;
    return c;
}

bool SLTemperatureRead(SLTemperatureConnection *c, const char *key, double *value) {
    if (!c || !key || strlen(key) != 4 || key[0] != 'T' || !value) return false;
    uint32_t code = keyCode(key), size = 0, type = 0;
    for (unsigned i = 0; i < c->count; i++) {
        if (c->cache[i].key == code) { size = c->cache[i].size; type = c->cache[i].type; break; }
    }
    SLWire request = {0}, reply = {0};
    request.key = code;
    if (!size) {
        request.operation = 9;
        if (!readMessage(c, &request, &reply)) return false;
        size = reply.info.size;
        type = reply.info.type;
        if (size == 0 || size > sizeof(reply.bytes)) return false;
        if (c->count < 32) {
            c->cache[c->count].key = code;
            c->cache[c->count].size = size;
            c->cache[c->count++].type = type;
        }
    }
    request.info.size = size;
    request.operation = 5;
    if (!readMessage(c, &request, &reply)) return false;
    if (type == keyCode("flt ") && size == 4) {
        float result;
        memcpy(&result, reply.bytes, sizeof(result));
        *value = result;
    } else if (type == keyCode("sp78") && size == 2) {
        int16_t raw = (int16_t)((uint16_t)reply.bytes[0] << 8 | reply.bytes[1]);
        *value = (double)raw / 256.0;
    } else {
        return false;
    }
    // Some inactive/unusable core channels return 1.5 or 2.2, not CPU temperatures.
    // Conservatively reject these rather than allowing them to distort the mean.
    return isfinite(*value) && *value >= 10 && *value <= 125;
}

void SLTemperatureClose(SLTemperatureConnection *c) {
    if (!c) return;
    IOServiceClose(c->port);
    free(c);
}
