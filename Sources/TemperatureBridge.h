#ifndef STATE_LITE_TEMPERATURE_BRIDGE_H
#define STATE_LITE_TEMPERATURE_BRIDGE_H
#include <stdbool.h>
typedef struct SLTemperatureConnection SLTemperatureConnection;
SLTemperatureConnection *SLTemperatureOpen(void);
bool SLTemperatureRead(SLTemperatureConnection *connection, const char *key, double *value);
void SLTemperatureClose(SLTemperatureConnection *connection);
#endif
