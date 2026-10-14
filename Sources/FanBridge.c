#include "FanBridge.h"
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

struct SLFanConnection {
    io_connect_t port;
    struct { uint32_t key, size, type; } cache[64];
    unsigned count;
};

static uint32_t keyCode(const char *s) {
    return (uint32_t)(uint8_t)s[0] << 24 | (uint32_t)(uint8_t)s[1] << 16 |
           (uint32_t)(uint8_t)s[2] << 8 | (uint8_t)s[3];
}

static kern_return_t fanLastKernel;
static uint8_t fanLastResult;
static uint32_t fanLastKey;
static uint8_t fanLastOperation;
static bool readMessage(SLFanConnection *c, SLWire *request, SLWire *reply) {
    size_t length = sizeof(*reply);
    memset(reply, 0, length);
    fanLastKernel=IOConnectCallStructMethod(c->port,2,request,sizeof(*request),reply,&length);
    fanLastResult=reply->result;fanLastKey=request->key;fanLastOperation=request->operation;
    return fanLastKernel==KERN_SUCCESS && length==sizeof(*reply) && reply->result==0;
}

SLFanConnection *SLFanOpen(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return NULL;
    io_connect_t port = 0;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &port);
    IOObjectRelease(service);
    if (result != KERN_SUCCESS) return NULL;
    SLFanConnection *c = calloc(1, sizeof(*c));
    if (!c) { IOServiceClose(port); return NULL; }
    c->port = port;
    return c;
}

bool SLFanRead(SLFanConnection *c, const char *key, double *value) {
    if (!c || !key || strlen(key) != 4 || (strcmp(key, "FNum") != 0 && !(key[0] == 'F' && key[1] >= '0' && key[1] <= '9' && (strcmp(key + 2, "Ac") == 0 || strcmp(key + 2, "Mn") == 0 || strcmp(key + 2, "Mx") == 0 || strcmp(key + 2, "Md") == 0 || strcmp(key + 2, "md") == 0 || strcmp(key + 2, "Tg") == 0))) || !value) return false;
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
        if (c->count < 64) {
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
    } else if (type == keyCode("fpe2") && size == 2) {
        *value = ((uint16_t)reply.bytes[0] << 8 | reply.bytes[1]) / 4.0;
    } else if (type == keyCode("ui8 ") && size == 1) {
        *value = reply.bytes[0];
    } else if (type == keyCode("ui16") && size == 2) {
        *value = ((uint16_t)reply.bytes[0] << 8 | reply.bytes[1]);
    } else {
        return false;
    }
    // Zero RPM is valid for a stopped fan. Interpretation/ranges are checked in Swift.
    return isfinite(*value) && *value >= 0 && *value <= 65535;
}

void SLFanClose(SLFanConnection *c) {
    if (!c) return;
    IOServiceClose(c->port);
    free(c);
}

#ifndef SL_FAN_HELPER
#include <Security/Authorization.h>
#include <Security/SecStaticCode.h>
#include <limits.h>
#include <Security/AuthorizationTags.h>
#include <libproc.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/socket.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static int SLFanAuthorizeAction(const char *path, const char *action, int *fd) {
    if (!path || !fd) return errAuthorizationInvalidPointer;
    *fd = -1;
    // Check sealed bundle resources before presenting the administrator prompt.
    // Ad-hoc signing detects accidental modification, not a trusted publisher identity.
    char bundle[PATH_MAX];
    if(strlen(path)>=sizeof(bundle))return -1;
    strcpy(bundle,path);
    for(int i=0;i<3;i++){char *slash=strrchr(bundle,'/');if(!slash)return -1;*slash=0;}
    CFURLRef url=CFURLCreateFromFileSystemRepresentation(NULL,(const UInt8 *)bundle,strlen(bundle),true);
    SecStaticCodeRef code=NULL;
    OSStatus validity=url?SecStaticCodeCreateWithPath(url,kSecCSDefaultFlags,&code):-1;
    if(!validity)validity=SecStaticCodeCheckValidity(code,kSecCSStrictValidate|kSecCSCheckNestedCode,NULL);
    if(code)CFRelease(code);if(url)CFRelease(url);
    if(validity)return validity;
    struct proc_bsdinfo info = {0};
    if (proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return -1;
    char pid[32], uid[32], sec[32], usec[32];
    snprintf(pid,sizeof(pid),"%d",getpid()); snprintf(uid,sizeof(uid),"%u",getuid());
    snprintf(sec,sizeof(sec),"%llu",info.pbi_start_tvsec); snprintf(usec,sizeof(usec),"%llu",info.pbi_start_tvusec);
    char *args[] = {(char *)action,pid,uid,sec,usec,NULL};
    AuthorizationRef auth = NULL;
    OSStatus status = AuthorizationCreate(NULL,kAuthorizationEmptyEnvironment,kAuthorizationFlagDefaults,&auth);
    if (status) return status;
    AuthorizationItem item={kAuthorizationRightExecute,0,NULL,0};
    AuthorizationRights rights={1,&item};
    status=AuthorizationCopyRights(auth,&rights,kAuthorizationEmptyEnvironment,
        kAuthorizationFlagInteractionAllowed|kAuthorizationFlagExtendRights|kAuthorizationFlagPreAuthorize,NULL);
    if(status){AuthorizationFree(auth,kAuthorizationFlagDestroyRights);return status;}
    FILE *channel = NULL;
    status = AuthorizationExecuteWithPrivileges(auth,path,kAuthorizationFlagDefaults,args,&channel);
    AuthorizationFree(auth,kAuthorizationFlagDestroyRights);
    if (status == errAuthorizationSuccess && channel) {
        *fd = dup(fileno(channel)); fclose(channel);
        if (*fd < 0) return -1;
        int enabled = 1;
        setsockopt(*fd,SOL_SOCKET,SO_NOSIGPIPE,&enabled,sizeof(enabled));
        fcntl(*fd,F_SETFD,FD_CLOEXEC);
    } else if (!status) return -1;
    return status;
}
#pragma clang diagnostic pop
int SLFanSend(int fd,char command) { return (int)write(fd,&command,1); }
void SLFanDisconnect(int fd) { if(fd >= 0) close(fd); }
#endif
#ifndef SL_FAN_HELPER
#include <poll.h>
int SLFanReceive(int fd,char *byte,int timeoutMS) {
    struct pollfd p={.fd=fd,.events=POLLIN};
    int r=poll(&p,1,timeoutMS);
    if(r==0)return 0;
    if(r<0)return -1;
    ssize_t n=read(fd,byte,1);
    if(n<0&&(errno==EINTR||errno==EAGAIN||errno==EWOULDBLOCK))return 0;
    return n==1?1:-1;
}
#endif

#ifndef SL_FAN_HELPER
int SLFanSendCommand(int fd,const char *command) {
    if(!command)return -1;size_t n=strlen(command);
    if(n==0||n>512||command[n-1]!='\n')return -1;
    int flags=fcntl(fd,F_GETFL);if(flags<0||fcntl(fd,F_SETFL,flags|O_NONBLOCK)<0)return -1;
    struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);
    double deadline=t.tv_sec+t.tv_nsec/1e9+0.2;size_t offset=0;
    while(offset<n) {
        clock_gettime(CLOCK_MONOTONIC,&t);double remaining=deadline-(t.tv_sec+t.tv_nsec/1e9);
        if(remaining<=0)return -1;
        ssize_t r=write(fd,command+offset,n-offset);
        if(r>0){offset+=(size_t)r;continue;}
        if(r<0&&errno==EINTR)continue;
        if(r<0&&(errno==EAGAIN||errno==EWOULDBLOCK)) {
            struct pollfd p={.fd=fd,.events=POLLOUT};
            int result=poll(&p,1,(int)(remaining*1000)+1);
            if(result<0&&errno==EINTR)continue;
            if(result<=0||(p.revents&(POLLERR|POLLHUP|POLLNVAL)))return -1;
            continue;
        }
        return -1;
    }
    return (int)n;
}
#include "FanServiceClient.c"
#endif
