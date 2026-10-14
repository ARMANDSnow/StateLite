// Temporary, fixed-purpose privileged fan lease worker. Never runs a command or shell.
// Build separately with -DSL_FAN_HELPER; include the bridge's private wire helpers.
#define SL_FAN_HELPER 1
#include "FanBridge.c"
#include <stdio.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <errno.h>
#include <libproc.h>
#include <sys/select.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <sys/mman.h>
#include <CommonCrypto/CommonDigest.h>
#include "FanLease.h"
#ifdef SL_FAN_TEST
static bool (*testWriter)(const char *,double);
static bool (*testReader)(const char *,double *);
static double testNow;
static bool testSkipPump, testSkipWait;
static const char *testErrorStage;
#endif
#ifndef SL_APP_SHA256
#define SL_APP_SHA256 "UNCONFIGURED"
#endif
static volatile sig_atomic_t stopped;
static void stopHandler(int sig) { (void)sig; stopped = 1; }
static double now(void) {
#ifdef SL_FAN_TEST
    if(testNow>0)return testNow;
#endif
    struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec+t.tv_nsec/1e9; }
#ifndef SL_FAN_TEST
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/IOMessage.h>
#include <CoreFoundation/CoreFoundation.h>
#include <pthread.h>
#include <stdatomic.h>
typedef struct {
    pthread_t thread;
    pthread_mutex_t lock;
    pthread_cond_t readyCondition;
    bool ready, valid;
    CFRunLoopRef loop;
    io_connect_t rootPort;
    _Atomic bool requested, stopRequested;
    _Atomic uintptr_t token;
} SLSleepMonitor;
static SLSleepMonitor *activeSleepMonitor;
static void sleepCallback(void *context,io_service_t service,natural_t message,void *argument) {
    (void)service;SLSleepMonitor *monitor=context;
    if(message==kIOMessageCanSystemSleep)IOAllowPowerChange(monitor->rootPort,(long)argument);
    else if(message==kIOMessageSystemWillSleep) {
        atomic_store(&monitor->token,(uintptr_t)argument);
        atomic_store(&monitor->requested,true); // No SMC access from the notification thread.
    }
}
static void *sleepThread(void *context) {
    SLSleepMonitor *monitor=context;IONotificationPortRef notification=NULL;io_object_t notifier=0;
    monitor->rootPort=IORegisterForSystemPower(monitor,&notification,sleepCallback,&notifier);
    CFRunLoopSourceRef source=notification?IONotificationPortGetRunLoopSource(notification):NULL;
    pthread_mutex_lock(&monitor->lock);
    monitor->valid=monitor->rootPort && source;
    if(monitor->valid){monitor->loop=CFRunLoopGetCurrent();CFRetain(monitor->loop);CFRunLoopAddSource(monitor->loop,source,kCFRunLoopCommonModes);}
    monitor->ready=true;pthread_cond_signal(&monitor->readyCondition);pthread_mutex_unlock(&monitor->lock);
    while(monitor->valid&&!atomic_load(&monitor->stopRequested))CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.25,false);
    // Caller reached here only after the serial SMC loop completed its recovery attempt.
    uintptr_t token=atomic_exchange(&monitor->token,0);
    if(atomic_exchange(&monitor->requested,false)&&monitor->rootPort)IOAllowPowerChange(monitor->rootPort,(long)token);
    if(notifier)IODeregisterForSystemPower(&notifier);
    if(monitor->rootPort)IOServiceClose(monitor->rootPort);
    if(notification)IONotificationPortDestroy(notification);
    return NULL;
}
static bool startSleepMonitor(SLSleepMonitor *monitor) {
    memset(monitor,0,sizeof(*monitor));pthread_mutex_init(&monitor->lock,NULL);pthread_cond_init(&monitor->readyCondition,NULL);
    if(pthread_create(&monitor->thread,NULL,sleepThread,monitor)){pthread_cond_destroy(&monitor->readyCondition);pthread_mutex_destroy(&monitor->lock);return false;}
    pthread_mutex_lock(&monitor->lock);while(!monitor->ready)pthread_cond_wait(&monitor->readyCondition,&monitor->lock);bool valid=monitor->valid;pthread_mutex_unlock(&monitor->lock);
    if(!valid){pthread_join(monitor->thread,NULL);pthread_cond_destroy(&monitor->readyCondition);pthread_mutex_destroy(&monitor->lock);return false;}
    activeSleepMonitor=monitor;return true;
}
static bool sleepWasRequested(void) {return activeSleepMonitor&&atomic_load(&activeSleepMonitor->requested);}
static void stopSleepMonitor(SLSleepMonitor *monitor) {
    atomic_store(&monitor->stopRequested,true);CFRunLoopStop(monitor->loop);CFRunLoopWakeUp(monitor->loop);pthread_join(monitor->thread,NULL);
    CFRelease(monitor->loop);activeSleepMonitor=NULL;pthread_cond_destroy(&monitor->readyCondition);pthread_mutex_destroy(&monitor->lock);
}
#else
typedef struct { int unused; } SLSleepMonitor;
static bool testSleepRequested;
static void (*testSleepAcknowledge)(void);
static bool startSleepMonitor(SLSleepMonitor *monitor) {(void)monitor;return true;}
static bool sleepWasRequested(void) {return testSleepRequested;}
static void stopSleepMonitor(SLSleepMonitor *monitor) {(void)monitor;if(testSleepRequested&&testSleepAcknowledge)testSleepAcknowledge();}
#endif
static bool metadata(SLFanConnection *c,const char *key,SLWire *out) {
    SLWire req={0}; req.key=keyCode(key); req.operation=9;
    return readMessage(c,&req,out) && out->info.size>0 && out->info.size<=32;
}
// Construct the private write wire with only the key's size, matching fan-dial/Stats.
// Type and attributes describe metadata replies; they are not write request fields.
static bool prepareWrite(const char *key,double value,const SLWire *metadata,SLWire *req) {
    memset(req,0,sizeof(*req));req->key=keyCode(key);req->info.size=metadata->info.size;req->operation=6;
    if(!isfinite(value))return false;
    if(metadata->info.type==keyCode("flt ")&&metadata->info.size==4){float f=(float)value;memcpy(req->bytes,&f,4);}
    else if(metadata->info.type==keyCode("ui8 ")&&metadata->info.size==1&&value>=0&&value<=255)req->bytes[0]=(uint8_t)value;
    else if(metadata->info.type==keyCode("fpe2")&&metadata->info.size==2&&value>=0&&value<16384){unsigned n=(unsigned)(value*4);req->bytes[0]=n>>8;req->bytes[1]=n;}
    else return false;
    return true;
}
static bool writeNumber(SLFanConnection *c,const char *key,double value) {
#ifdef SL_FAN_TEST
    if(testWriter)return testWriter(key,value);
#endif
    SLWire m={0},req={0},out={0};
    if(!metadata(c,key,&m)||!prepareWrite(key,value,&m,&req))return false;
    return readMessage(c,&req,&out);
}
static bool readNumber(SLFanConnection *c,const char *key,double *value) {
#ifdef SL_FAN_TEST
    if(testReader)return testReader(key,value);
#endif
    SLWire m={0},req={0},out={0};
    if(!metadata(c,key,&m))return false;
    req.key=keyCode(key);req.info.size=m.info.size;req.operation=5;
    if(!readMessage(c,&req,&out))return false;
    if(m.info.type==keyCode("ui8 ")&&m.info.size==1)*value=out.bytes[0];
    else if(m.info.type==keyCode("flt ")&&m.info.size==4){float f;memcpy(&f,out.bytes,4);*value=f;}
    else if(m.info.type==keyCode("fpe2")&&m.info.size==2)*value=((unsigned)out.bytes[0]*256+out.bytes[1])/4.0;
    else return false;
    return isfinite(*value);
}
static bool fixedByte(SLFanConnection *c,const char *key) {
    SLWire m={0};return metadata(c,key,&m)&&m.info.type==keyCode("ui8 ")&&m.info.size==1;
}
static bool targetType(SLFanConnection *c,const char *key) {
    SLWire m={0}; return metadata(c,key,&m)&&((m.info.type==keyCode("flt ")&&m.info.size==4)||(m.info.type==keyCode("fpe2")&&m.info.size==2));
}
static char modes[10][5];
static double maxima[10], minima[10];
static int fans;
static bool hasFtst;
static bool discover(SLFanConnection *c) {
    double n;
    if(!SLFanRead(c,"FNum",&n)||n<1||n>10||n!=(int)n) return false;
    fans=(int)n;
    hasFtst=fixedByte(c,"Ftst");
    for(int i=0;i<fans;i++) {
        char k[5]; snprintf(modes[i],5,"F%dmd",i);
        if(!fixedByte(c,modes[i])) snprintf(modes[i],5,"F%dMd",i);
        if(!fixedByte(c,modes[i])) return false;
        snprintf(k,5,"F%dMx",i);
        if(!SLFanRead(c,k,&maxima[i])||maxima[i]<1000||maxima[i]>16000) return false;
        snprintf(k,5,"F%dMn",i);
        if(!SLFanRead(c,k,&minima[i])||minima[i]<0||minima[i]>maxima[i])return false;
        snprintf(k,5,"F%dTg",i);if(!targetType(c,k)) return false;
    }
    return true;
}
static bool restore(SLFanConnection *c) {
    // Ownership changes asynchronously. Retry only rejected automatic-mode writes (0x82),
    // never targets, and require two complete observations before declaring restoration.
    double until=now()+3;bool pending[11]={0};int count=fans+(hasFtst?1:0),consecutive=0;
    uint32_t mismatchKey=0;
    for(int i=0;i<count;i++)pending[i]=true;
    for(int attempt=0;attempt<31&&now()<until;attempt++) {
        bool fatal=false;uint32_t failedKey=0;kern_return_t failedKernel=0;uint8_t failedResult=0;
        for(int i=0;i<count;i++)if(pending[i]) {
            const char *key=i<fans?modes[i]:"Ftst";
            if(writeNumber(c,key,0))pending[i]=false;
            else if(fanLastKernel!=KERN_SUCCESS||fanLastResult!=0x82){if(!fatal){failedKey=fanLastKey;failedKernel=fanLastKernel;failedResult=fanLastResult;}fatal=true;}
        }
        // Still attempt all automatic-mode writes before returning a fatal write error.
        if(fatal){fanLastKey=failedKey;fanLastKernel=failedKernel;fanLastResult=failedResult;fanLastOperation=6;return false;}
        bool matched=true;double globalMode=0;
        if(hasFtst) {
            if(!readNumber(c,"Ftst",&globalMode))return false;
            if(globalMode!=0&&globalMode!=1)return false;
            if(globalMode!=0){matched=false;mismatchKey=keyCode("Ftst");}
        }
        for(int i=0;i<fans;i++) {
            double mode=-1;if(!readNumber(c,modes[i],&mode))return false;
            if(mode!=0&&mode!=1&&mode!=3)return false;
            if(mode==1){matched=false;mismatchKey=keyCode(modes[i]);}
        }
        // A 0x82 write refusal can coincide with firmware already reclaiming control;
        // confirmed ownership is sufficient, even if that write was unnecessary.
        consecutive=matched?consecutive+1:0;
        if(consecutive>=2&&now()<until)return true;
#ifdef SL_FAN_TEST
        if(testSkipWait)continue;
#endif
        if(attempt<30&&now()<until)usleep(100000);
    }
    // Never clear targets, including on timeout: firmware owns the eventual speed choice.
    if(mismatchKey){fanLastKey=mismatchKey;fanLastOperation=5;}
    return false;
}
static bool parentMatches(pid_t pid,uid_t uid,unsigned long long sec,unsigned long long usec) {
    struct proc_bsdinfo p={0};
    return proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&p,sizeof(p))==sizeof(p)&&p.pbi_uid==uid&&p.pbi_start_tvsec==sec&&p.pbi_start_tvusec==usec;
}
static bool verifyParentImage(pid_t pid) {
    char actual[PROC_PIDPATHINFO_MAXSIZE],own[PROC_PIDPATHINFO_MAXSIZE],expected[PROC_PIDPATHINFO_MAXSIZE];
    uint32_t length=sizeof(own);
    if(!proc_pidpath(pid,actual,sizeof(actual))||_NSGetExecutablePath(own,&length)) return false;
    if(!realpath(own,expected)) return false;
    char *slash=strrchr(expected,'/');if(!slash)return false;
    strcpy(slash+1,"StateLite");
    char resolved[PROC_PIDPATHINFO_MAXSIZE];if(!realpath(actual,resolved)||strcmp(expected,resolved))return false;
    int file=open(resolved,O_RDONLY|O_CLOEXEC);struct stat st={0};
    if(file<0||fstat(file,&st)||st.st_size<(off_t)sizeof(struct mach_header_64)){if(file>=0)close(file);return false;}
    size_t size=(size_t)st.st_size;const uint8_t *bytes=mmap(NULL,size,PROT_READ,MAP_PRIVATE,file,0);close(file);
    if(bytes==MAP_FAILED)return false;
    const struct mach_header_64 *header=(const void *)bytes;
    bool ok=header->magic==MH_MAGIC_64&&header->cputype==CPU_TYPE_ARM64&&header->sizeofcmds<=size-sizeof(*header);
    CC_SHA256_CTX ctx;CC_SHA256_Init(&ctx);unsigned char digest[32];size_t pos=sizeof(*header);unsigned seen=0;
    for(unsigned i=0;ok&&i<header->ncmds;i++) {
        if(pos>sizeof(*header)+header->sizeofcmds||pos+sizeof(struct load_command)>size){ok=false;break;}
        const struct load_command *cmd=(const void *)(bytes+pos);
        if(cmd->cmdsize<8||cmd->cmdsize>sizeof(*header)+header->sizeofcmds-pos){ok=false;break;}
        if(cmd->cmd==LC_SEGMENT_64) {
            if(cmd->cmdsize<sizeof(struct segment_command_64)){ok=false;break;}
            const struct segment_command_64 *seg=(const void *)cmd;
            if(seg->nsects>(cmd->cmdsize-sizeof(*seg))/sizeof(struct section_64)){ok=false;break;}
            const struct section_64 *sections=(const void *)(seg+1);
            for(unsigned j=0;j<seg->nsects;j++) {
                const struct section_64 *sec=&sections[j];uint32_t type=sec->flags&SECTION_TYPE;
                if(type==S_ZEROFILL||type==S_GB_ZEROFILL||type==S_THREAD_LOCAL_ZEROFILL||!sec->size)continue;
                if(!sec->offset||sec->offset>size||sec->size>size-sec->offset||sec->size>UINT32_MAX){ok=false;break;}
                CC_SHA256_Update(&ctx,sec->segname,16);CC_SHA256_Update(&ctx,sec->sectname,16);
                CC_SHA256_Update(&ctx,&sec->size,8);CC_SHA256_Update(&ctx,bytes+sec->offset,(CC_LONG)sec->size);seen++;
            }
        }
        pos+=cmd->cmdsize;
    }
    CC_SHA256_Final(digest,&ctx);munmap((void *)bytes,size);ok=ok&&seen>0;
    char hex[65];for(int i=0;i<32;i++)snprintf(hex+2*i,3,"%02x",digest[i]);
    return ok && strcmp(hex,SL_APP_SHA256)==0;
}
static void reportReadbackError(unsigned request,const char *stage,double expected,double observed) {
#ifdef SL_FAN_TEST
    testErrorStage=stage;
#endif
    char key[5]={(char)(fanLastKey>>24),(char)(fanLastKey>>16),(char)(fanLastKey>>8),(char)fanLastKey,0};
    for(int i=0;i<4;i++)if(key[i]<32||key[i]>126)key[i]='?';
    printf("ERROR %u stage=%s key=%s op=%u kernel=0x%08x smc=%u",request,stage,key,fanLastOperation,fanLastKernel,fanLastResult);
    if(isfinite(expected))printf(" expected=%.2f observed=%.2f",expected,observed);
    puts("");
}
static void reportError(unsigned request,const char *stage) {reportReadbackError(request,stage,NAN,NAN);}
static bool parseTargets(char *line,unsigned *request,double target[10]) {
    char *save=NULL,*word=strtok_r(line," ",&save);if(!word||strcmp(word,"SET"))return false;
    word=strtok_r(NULL," ",&save);if(!word)return false;char *end=NULL;
    unsigned long id=strtoul(word,&end,10);if(!id||*end||id>UINT32_MAX)return false;*request=(unsigned)id;
    bool seen[10]={0};int count=0;
    while((word=strtok_r(NULL," ",&save))) {
        long fan=strtol(word,&end,10);if(end==word||*end!='='||fan<0||fan>=fans||seen[fan])return false;
        const char *start=end+1;double value=strtod(start,&end);
        if(end==start||*end||!isfinite(value)||value<minima[fan]||value>maxima[fan])return false;
        seen[fan]=true;target[fan]=value;count++;
    }
    return count==fans;
}
static bool pumpTransition(pid_t pid,uid_t uid,unsigned long long sec,unsigned long long usec,double *deadline,char line[512],size_t *used) {
#ifdef SL_FAN_TEST
    if(testSkipPump)return !stopped&&!sleepWasRequested()&&parentMatches(pid,uid,sec,usec)&&now()<*deadline;
#endif
    // Drain heartbeat frames during a slow SMC transition; ACK never renews a lease.
    while(!stopped&&!sleepWasRequested()) {
        fd_set fds;FD_ZERO(&fds);FD_SET(STDIN_FILENO,&fds);struct timeval zero={0,0};
        int ready=select(STDIN_FILENO+1,&fds,NULL,NULL,&zero);
        if(ready<0){if(errno==EINTR)continue;return false;}if(!ready)break;
        char b;if(read(STDIN_FILENO,&b,1)!=1)return false;
        if(b!='\n'){if(*used>=511||b<32||b>126)return false;line[(*used)++]=b;continue;}
        line[*used]=0;*used=0;
        if(!strcmp(line,"PING"))*deadline=now()+10;
        else return false; // Exit/system/cancel during transition must restore, never continue writes.
    }
    return !stopped&&!sleepWasRequested()&&parentMatches(pid,uid,sec,usec)&&now()<*deadline;
}
typedef enum { SLWriteOK, SLWriteFailed, SLWriteTimeout, SLWriteLeaseExpired } SLWriteOutcome;
static SLWriteOutcome writeDuringHandoff(SLFanConnection *c,const char *key,double value,double until,int maxRetries,pid_t pid,uid_t uid,unsigned long long sec,unsigned long long usec,double *deadline,char line[512],size_t *used) {
    // Both Md and Tg may return transient 0x82 after Ftst. A mode read of 0 is not
    // permission to write; acceptance is established by the actual write and readback.
    for(int attempt=0;attempt<=maxRetries;attempt++) {
        if(!pumpTransition(pid,uid,sec,usec,deadline,line,used))return SLWriteLeaseExpired;
        if(now()>=until)return SLWriteTimeout;
        if(writeNumber(c,key,value))return SLWriteOK;
        if(fanLastKernel!=KERN_SUCCESS||fanLastResult!=0x82)return SLWriteFailed;
        if(attempt==maxRetries||now()>=until)return SLWriteTimeout;
#ifdef SL_FAN_TEST
        if(testSkipWait)continue;
#endif
        usleep(100000);
    }
    return SLWriteTimeout;
}
static const char *writeFailureStage(SLWriteOutcome outcome,bool mode) {
    if(outcome==SLWriteLeaseExpired)return "transition_lease_expired";
    if(outcome==SLWriteTimeout)return mode?"mode_write_timeout":"target_write_timeout";
    return mode?"mode_write":"target_write";
}
typedef enum { SLPairStable, SLPairTransient, SLPairFatal } SLPairOutcome;
typedef struct { const char *stage; uint32_t key; double expected, observed; } SLPairMismatch;
static SLPairOutcome observeTargets(SLFanConnection *c,const double targets[10],unsigned request,pid_t pid,uid_t uid,unsigned long long sec,unsigned long long usec,double *deadline,char line[512],size_t *used,double handoffEnd,SLPairMismatch *mismatch) {
    double until=fmin(now()+1,handoffEnd);int consecutive=0;
    for(int attempt=0;attempt<11;attempt++) {
        if(!pumpTransition(pid,uid,sec,usec,deadline,line,used)){reportError(request,"transition_lease_expired");return SLPairFatal;}
        if(now()>=until)return SLPairTransient;
        bool matched=true;
        for(int i=0;i<fans;i++) {
            char key[5];snprintf(key,5,"F%dTg",i);double mode=NAN,target=NAN;
            if(!readNumber(c,modes[i],&mode)){reportError(request,"mode_read");return SLPairFatal;}
            if(mode!=0&&mode!=1&&mode!=3){reportReadbackError(request,"mode_unknown",1,mode);return SLPairFatal;}
            if(!pumpTransition(pid,uid,sec,usec,deadline,line,used)){reportError(request,"transition_lease_expired");return SLPairFatal;}
            if(!readNumber(c,key,&target)){reportError(request,"target_read");return SLPairFatal;}
            if(mode!=1){matched=false;*mismatch=(SLPairMismatch){"mode_final_readback",keyCode(modes[i]),1,mode};}
            else if(fabs(target-targets[i])>=1){matched=false;*mismatch=(SLPairMismatch){"target_final_readback",keyCode(key),targets[i],target};}
        }
        consecutive=matched?consecutive+1:0;
        if(consecutive>=2)return SLPairStable;
        if(attempt==10||now()>=until)return SLPairTransient;
#ifdef SL_FAN_TEST
        if(testSkipWait)continue;
#endif
        usleep(100000);
    }
    return SLPairTransient;
}
static bool applyTargets(SLFanConnection *c,const double targets[10],unsigned request,pid_t pid,uid_t uid,unsigned long long sec,unsigned long long usec,bool alreadyActive,double *deadline,char line[512],size_t *used) {
    // One shared budget includes all complete replays, all fans, and paired verification.
    double handoffEnd=now()+16;
    if(!alreadyActive&&hasFtst) {
        if(!writeNumber(c,"Ftst",1)){reportError(request,"unlock_Ftst");return false;}
    }
    SLPairMismatch mismatch={"handoff_unconfirmed",0,NAN,NAN};
    for(int replay=0;replay<3;replay++) {
        for(int i=0;i<fans;i++) {
            if(!pumpTransition(pid,uid,sec,usec,deadline,line,used)){reportError(request,"transition_lease_expired");return false;}
            char key[5];snprintf(key,5,"F%dTg",i);
            // A successful mode write is followed immediately by the target write.
            // Some firmware updates readable Md only after it receives Tg.
            SLWriteOutcome modeWrite=writeDuringHandoff(c,modes[i],1,fmin(now()+12,handoffEnd),120,pid,uid,sec,usec,deadline,line,used);
            if(modeWrite!=SLWriteOK){reportError(request,now()>=handoffEnd?"handoff_budget_expired":writeFailureStage(modeWrite,true));return false;}
            SLWriteOutcome targetWrite=writeDuringHandoff(c,key,targets[i],fmin(now()+2,handoffEnd),20,pid,uid,sec,usec,deadline,line,used);
            if(targetWrite!=SLWriteOK){reportError(request,now()>=handoffEnd?"handoff_budget_expired":writeFailureStage(targetWrite,false));return false;}
        }
        SLPairOutcome result=observeTargets(c,targets,request,pid,uid,sec,usec,deadline,line,used,handoffEnd,&mismatch);
        if(result==SLPairFatal)return false;
        if(result==SLPairStable) {
            if(!pumpTransition(pid,uid,sec,usec,deadline,line,used)){reportError(request,"transition_lease_expired");return false;}
            if(now()<handoffEnd)return true;
        }
        if(now()>=handoffEnd){reportError(request,"handoff_budget_expired");return false;}
        // Only known modes 0/1/3 and successful reads reach here. Reapply the complete
        // sequence, never silently accept system ownership or an overwritten target.
    }
    fanLastKey=mismatch.key;fanLastOperation=5;
    reportReadbackError(request,mismatch.stage,mismatch.expected,mismatch.observed);
    return false;
}
static bool runLease(SLFanConnection *c,pid_t pid,uid_t uid,unsigned long long sec,unsigned long long usec) {
    stopped=0;
    SLSleepMonitor sleepMonitor;
    if(!startSleepMonitor(&sleepMonitor)){puts("ERROR 0 stage=sleep_monitor_unavailable");return false;}
    signal(SIGPIPE,SIG_IGN);signal(SIGTERM,stopHandler);signal(SIGINT,stopHandler);signal(SIGHUP,stopHandler);
    puts("READY");double started=now(),deadline=started+10;bool dirty=false,active=false;
    char line[512];size_t used=0;unsigned request=0;
    while(SLFanLeaseValid(now(),started,deadline,parentMatches(pid,uid,sec,usec),stopped||sleepWasRequested())) {
        fd_set readset;FD_ZERO(&readset);FD_SET(STDIN_FILENO,&readset);struct timeval timeout={0,250000};
        int r=select(STDIN_FILENO+1,&readset,NULL,NULL,&timeout);
        if(r<0){if(errno==EINTR)continue;break;}if(!r)continue;
        char byte;if(read(STDIN_FILENO,&byte,1)!=1)break;
        if(byte!='\n'){if(used>=sizeof(line)-1||byte<32||byte>126){reportError(0,"invalid_frame");break;}line[used++]=byte;continue;}
        line[used]=0;used=0;
        if(!strcmp(line,"PING")){deadline=now()+10;continue;}
        unsigned restoreID=0;char extra;
        if(sscanf(line,"SYSTEM %u %c",&restoreID,&extra)==1&&restoreID>0) {
            bool ok=!dirty||restore(c);
            if(ok){dirty=false;active=false;printf("ACK %u SYSTEM\n",restoreID);}else{reportError(restoreID,"restore");break;}
            break; // System ownership ends the privileged session and heartbeat work.
        }
        double targets[10]={0};request=0;
        if(!parseTargets(line,&request,targets)){reportError(request,"invalid_targets_or_range");continue;}
        deadline=now()+10;dirty=true;
        if(!applyTargets(c,targets,request,pid,uid,sec,usec,active,&deadline,line,&used))break;
        active=true;printf("ACK %u TARGETS",request);
        for(int i=0;i<fans;i++)printf(" %d=%.2f",i,targets[i]);puts("");
    }
    bool restored=!dirty;
    if(dirty){for(int i=0;i<10&&!restored;i++){restored=restore(c);if(!restored)usleep(100000);}if(restored)puts("RESTORED");else reportError(request,"exit_restore_failed");}
    stopSleepMonitor(&sleepMonitor); // Acknowledge sleep only after recovery, even when recovery failed.
    return restored; // Service retains its durable dirty marker on failure.
}
#ifndef SL_FAN_TEST
#include "FanService.c"
#endif
int main(int argc,char **argv) {
#ifndef SL_FAN_TEST
    int serviceResult=SLFanServiceCommand(argc,argv);
    if(serviceResult>=0)return serviceResult;
#endif
    // --probe only reads. It deliberately never claims that readable metadata proves write access.
    bool probe=argc==2&&!strcmp(argv[1],"--probe");
    setbuf(stdout,NULL);
    if(!probe && (argc!=6||strcmp(argv[1],"--lease")||geteuid()!=0)){puts("ERROR 0 stage=arguments_or_root");return 64;}
    pid_t pid=probe?0:(pid_t)strtol(argv[2],NULL,10);uid_t uid=probe?0:(uid_t)strtoul(argv[3],NULL,10);
    unsigned long long sec=probe?0:strtoull(argv[4],NULL,10),usec=probe?0:strtoull(argv[5],NULL,10);
    if(!probe&&(pid<=1||uid==0||!parentMatches(pid,uid,sec,usec))){puts("ERROR 0 stage=parent_identity");return 65;}
    if(!probe&&!verifyParentImage(pid)){puts("ERROR 0 stage=parent_image_hash");return 65;}
    SLFanConnection *c=SLFanOpen();if(!c){puts("ERROR 0 stage=smc_open");return 66;}
    bool ready=discover(c);
    if(probe) {printf("readable_control_metadata=%s fans=%d Ftst=%s; write_permission=UNTESTED\n",ready?"yes":"no",fans,hasFtst?"yes":"no");for(int i=0;i<fans;i++)printf("fan=%d mode_key=%s max=%.0f\n",i,modes[i],maxima[i]);SLFanClose(c);return ready?0:67;}
    // Stable root-owned lock file; do not unlink while other processes could hold its inode.
    int lockFD=open("/private/var/run/statelite-fan.lock",O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0600);
    struct stat lockStat={0};
    if(lockFD<0||fstat(lockFD,&lockStat)||!S_ISREG(lockStat.st_mode)||lockStat.st_uid!=0||(lockStat.st_mode&077)||flock(lockFD,LOCK_EX|LOCK_NB)) {
        puts("ERROR 0 stage=another_session_or_unsafe_lock");SLFanClose(c);return 68;
    }
    setbuf(stdout,NULL);
    if(!ready){puts("ERROR 0 stage=unsupported_metadata");SLFanClose(c);return 67;}
    bool restored=runLease(c,pid,uid,sec,usec);
    SLFanClose(c);return restored?0:69;
}
