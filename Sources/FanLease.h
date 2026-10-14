#ifndef STATE_LITE_FAN_LEASE_H
#define STATE_LITE_FAN_LEASE_H
#include <stdbool.h>
#include <math.h>
// Continued heartbeats renew ownership; missing heartbeat or parent death always expires it.
static inline bool SLFanLeaseValid(double now,double started,double deadline,bool parentAlive,bool stop) {
    return !stop && parentAlive && isfinite(now) && now>=started && now<deadline;
}
#endif
