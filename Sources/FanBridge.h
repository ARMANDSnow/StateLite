#ifndef STATE_LITE_FAN_BRIDGE_H
#define STATE_LITE_FAN_BRIDGE_H
#include <stdbool.h>
typedef struct SLFanConnection SLFanConnection;
SLFanConnection *SLFanOpen(void);
bool SLFanRead(SLFanConnection *, const char *key, double *value);
void SLFanClose(SLFanConnection *);
// Returns Authorization Services status; fd is a duplex helper channel on success.
int SLFanLaunchHelper(const char *path, int *fd);
// 0 installed for this build; 1 absent; 2 upgrade required; negative validation failure.
int SLFanHelperInstallationState(const char *path);
int SLFanRemoveInstalledHelper(const char *path);
const char *SLFanLastServiceError(void);
int SLFanSend(int fd, char command);
void SLFanDisconnect(int fd);
// 1 byte, 0 timeout, -1 EOF/error. timeout bounded to caller-supplied milliseconds.
int SLFanReceive(int fd, char *byte, int timeoutMS);
int SLFanSendCommand(int fd, const char *command);
#endif
