#define SL_FAN_TEST 1
#define main helper_main
#include "../Sources/FanHelper.c"
#undef main
#include <assert.h>
#include <sys/socket.h>
#include <sys/wait.h>
static double fakeMode[2],fakeTarget[2],fakeFtst;
static bool failFirstRestore, failGlobalRestore, systemReclaim, wrongReadback;
static int targetZeroCalls;
static bool rejectManualMode, rejectSecondTarget;
static int ignoredAutoTargets;
static int targetBusyWrites, targetAttempts, targetLagReads;
static int modeBusyWrites[2], modeAttempts[2];
static bool modePermissionDenied, modeReadbackWrong;
static double modeBusySeconds;
static bool targetPermissionDenied;
static bool modeNeedsTarget, pendingManual[2], overrideAlways, overrideOnce, readPermissionDenied;
static int modeLagReads, unknownMode;
static int restoreGlobalLag,restoreModeLag,restoreBusyWrites,restoreWriteAttempts;
static bool restoreNeverSettles;


static int injectedHeartbeatFD = -1;
static bool sleepOnTarget, sleepAcked, expectSleepRestore;
static void acknowledgeSleepMock(void) {
    sleepAcked=true;
    assert((fakeMode[0]==0&&fakeMode[1]==0)==expectSleepRestore);
}
static int yieldAfterReads = -1;
static bool fakeWrite(const char *key,double value) {
    fanLastKey=keyCode(key);fanLastOperation=6;fanLastKernel=KERN_SUCCESS;fanLastResult=0;
    if(value==0){restoreWriteAttempts++;if(restoreBusyWrites>0){restoreBusyWrites--;fanLastResult=0x82;return false;}}
    if(!strcmp(key,"Ftst")){if(failGlobalRestore&&value==0)return false;fakeFtst=value;if(systemReclaim&&value==0){fakeMode[0]=fakeMode[1]=3;}return true;}
    int fan=key[1]-'0';assert(fan>=0&&fan<2);
    if(!strcmp(key+2,"md")){
        if(failFirstRestore&&fan==0&&value==0)return false;
        if(value==1){
            modeAttempts[fan]++;
            if(modePermissionDenied){fanLastKernel=kIOReturnNotPrivileged;return false;}
            if(modeBusyWrites[fan]>0){modeBusyWrites[fan]--;fanLastResult=0x82;if(testNow>0)testNow+=modeBusySeconds;return false;}
        }
        if(rejectManualMode&&value==1)return false;
        if(value==1&&modeNeedsTarget)pendingManual[fan]=true;
        else {fakeMode[fan]=value;pendingManual[fan]=false;}
        if(value==1)yieldAfterReads=-1;
    } else {
        assert(!strcmp(key+2,"Tg"));
        if(value==0){assert(fakeMode[fan]==0);targetZeroCalls++;}
        if(fakeMode[fan]!=1&&!pendingManual[fan]){ignoredAutoTargets++;return true;} // Firmware accepts but ignores auto-mode target writes.
        if(rejectSecondTarget&&fan==1)return false;
        targetAttempts++;
        if(targetPermissionDenied){fanLastKernel=kIOReturnNotPrivileged;return false;}
        if(targetBusyWrites>0){targetBusyWrites--;fanLastResult=0x82;return false;}
        fakeTarget[fan]=value;if(pendingManual[fan]){fakeMode[fan]=1;pendingManual[fan]=false;}
        if(overrideAlways){fakeMode[fan]=3;fakeTarget[fan]=2300;}
        if(overrideOnce&&fan==1){fakeMode[0]=0;fakeTarget[0]=2300;overrideOnce=false;}
        if(sleepOnTarget){sleepOnTarget=false;testSleepRequested=true;}
        if(injectedHeartbeatFD>=0){testNow+=12;assert(write(injectedHeartbeatFD,"PING\n",5)==5);close(injectedHeartbeatFD);injectedHeartbeatFD=-1;}
    }
    return true;
}
static bool fakeRead(const char *key,double *value) {
    fanLastKey=keyCode(key);fanLastOperation=5;fanLastKernel=KERN_SUCCESS;fanLastResult=0;
    if(readPermissionDenied){fanLastKernel=kIOReturnNotPrivileged;return false;}
    if(!strcmp(key,"Ftst")){*value=fakeFtst;if(fakeFtst==0&&restoreGlobalLag>0){restoreGlobalLag--;*value=1;}return true;}
    int fan=key[1]-'0';
    if(!strcmp(key+2,"md")&&fakeFtst==1&&yieldAfterReads>=0){if(yieldAfterReads>0){yieldAfterReads--;fakeMode[fan]=3;}else fakeMode[fan]=0;}
    *value=!strcmp(key+2,"md")?fakeMode[fan]:fakeTarget[fan]+(wrongReadback?100:0);
    if(!strcmp(key+2,"md")&&modeReadbackWrong&&fakeMode[fan]==1)*value=0;
    if(!strcmp(key+2,"md")&&modeLagReads>0){modeLagReads--;*value=0;}
    if(!strcmp(key+2,"md")&&unknownMode)*value=unknownMode;
    if(!strcmp(key+2,"md")&&fakeMode[fan]==0&&restoreModeLag>0){restoreModeLag--;*value=1;}
    if(!strcmp(key+2,"md")&&restoreNeverSettles)*value=1;
    if(!strcmp(key+2,"Tg")&&targetLagReads>0){targetLagReads--;*value-=100;}
    return true;
}
int main(void) {
    SLWire meta={0},wire={0};meta.info.size=1;meta.info.type=keyCode("ui8 ");meta.info.attributes=0xff;
    assert(prepareWrite("F0Md",1,&meta,&wire));
    assert(sizeof(wire)==80&&offsetof(SLWire,operation)==42&&offsetof(SLWire,bytes)==48);
    assert(wire.info.size==1&&wire.info.type==0&&wire.info.attributes==0&&wire.operation==6&&wire.bytes[0]==1);
    const unsigned char expectedModeWire[80]={[0]='d',[1]='M',[2]='0',[3]='F',[28]=1,[42]=6,[48]=1};
    assert(memcmp(&wire,expectedModeWire,80)==0); // Every reserved byte must be zero.
    assert(prepareWrite("Ftst",1,&meta,&wire));
    const unsigned char expectedUnlockWire[80]={[0]='t',[1]='s',[2]='t',[3]='F',[28]=1,[42]=6,[48]=1};
    assert(memcmp(&wire,expectedUnlockWire,80)==0);
    meta.info.size=4;meta.info.type=keyCode("flt ");assert(prepareWrite("F0Tg",3500,&meta,&wire));
    assert(wire.bytes[0]==0&&wire.bytes[1]==0xc0&&wire.bytes[2]==0x5a&&wire.bytes[3]==0x45);
    const unsigned char expectedTargetWire[80]={[0]='g',[1]='T',[2]='0',[3]='F',[28]=4,[42]=6,[49]=0xc0,[50]=0x5a,[51]=0x45};
    assert(memcmp(&wire,expectedTargetWire,80)==0);
    meta.info.size=2;meta.info.type=keyCode("fpe2");assert(prepareWrite("F0Tg",3500,&meta,&wire));assert(wire.bytes[0]==0x36&&wire.bytes[1]==0xb0);
    assert(!prepareWrite("F0Tg",NAN,&meta,&wire));
    assert(SLFanLeaseValid(109,100,110,true,false));
    assert(!SLFanLeaseValid(110,100,110,true,false));
    assert(SLFanLeaseValid(220,100,500,true,false)); // A live renewed lease continues beyond two minutes.
    assert(!SLFanLeaseValid(109,100,110,false,false));
    assert(!SLFanLeaseValid(109,100,110,true,true));
    assert(!SLFanLeaseValid(99,100,110,true,false));
    assert(!SLFanLeaseValid(NAN,100,110,true,false));
    fans=2;hasFtst=true;strcpy(modes[0],"F0md");strcpy(modes[1],"F1md");
    maxima[0]=maxima[1]=7800;minima[0]=minima[1]=2300;fakeMode[0]=fakeMode[1]=1;fakeTarget[0]=fakeTarget[1]=7800;
    testWriter=fakeWrite;testReader=fakeRead;failFirstRestore=true;
    assert(!restore(NULL));assert(fakeTarget[0]==7800&&fakeTarget[1]==7800&&targetZeroCalls==0);
    failFirstRestore=false;assert(restore(NULL));assert(fakeMode[0]==0&&fakeTarget[0]==7800);
    failGlobalRestore=true;fakeFtst=1;fakeTarget[0]=fakeTarget[1]=7800;
    assert(!restore(NULL));assert(fakeTarget[0]==7800&&fakeTarget[1]==7800);
    failGlobalRestore=false;assert(restore(NULL));
    systemReclaim=true;assert(restore(NULL));assert(fakeMode[0]==3&&fakeMode[1]==3);systemReclaim=false;
    testSkipWait=true;restoreGlobalLag=4;restoreModeLag=6;
    assert(restore(NULL)&&restoreGlobalLag==0&&restoreModeLag==0);
    restoreBusyWrites=4;restoreWriteAttempts=0;fakeMode[0]=fakeMode[1]=1;fakeFtst=1;
    assert(restore(NULL)&&restoreBusyWrites==0&&restoreWriteAttempts>3);
    restoreNeverSettles=true;restoreWriteAttempts=0;
    assert(!restore(NULL)&&restoreWriteAttempts==3&&targetZeroCalls==0);restoreNeverSettles=false;
    readPermissionDenied=true;assert(!restore(NULL));readPermissionDenied=false;
    restoreBusyWrites=1000;fakeMode[0]=fakeMode[1]=1;fakeFtst=1;restoreWriteAttempts=0;
    assert(!restore(NULL)&&restoreWriteAttempts<=93);restoreBusyWrites=0;assert(restore(NULL));testSkipWait=false;
    double parsed[10];unsigned request;
    char valid[]="SET 7 0=3000 1=3500";assert(parseTargets(valid,&request,parsed)&&request==7&&parsed[1]==3500);
    const char *invalid[]={"SET 1 0=3000","SET 1 0=3000 0=4000","SET 1 0=nan 1=4000","SET 1 0=2000 1=4000","SET 1 0=3000 1=8000","SET 1 0=3000 2=4000"};
    for(unsigned i=0;i<sizeof(invalid)/sizeof(invalid[0]);i++){char copy[128];strcpy(copy,invalid[i]);assert(!parseTargets(copy,&request,parsed));}
    struct proc_bsdinfo p={0};
    assert(proc_pidinfo(getpid(),PROC_PIDTBSDINFO,0,&p,sizeof(p))==sizeof(p));
    assert(parentMatches(getpid(),getuid(),p.pbi_start_tvsec,p.pbi_start_tvusec));
    assert(!parentMatches(getpid(),getuid(),p.pbi_start_tvsec+1,p.pbi_start_tvusec));
    testSkipPump=true;testSkipWait=true;
    hasFtst=false;wrongReadback=true;double mismatchTargets[10]={3000,3500};
    double deadline=now()+10;char partial[512];size_t partialUsed=0;
    assert(!applyTargets(NULL,mismatchTargets,8,getpid(),getuid(),p.pbi_start_tvsec,p.pbi_start_tvusec,false,&deadline,partial,&partialUsed));
    wrongReadback=false;assert(restore(NULL));
    hasFtst=false;fakeMode[0]=fakeMode[1]=0;fakeTarget[0]=fakeTarget[1]=2300;
    assert(fakeWrite("F0Tg",3000)&&fakeTarget[0]==2300&&ignoredAutoTargets==1);
    int ignoredBefore=ignoredAutoTargets;
    assert(applyTargets(NULL,mismatchTargets,11,getpid(),getuid(),p.pbi_start_tvsec,p.pbi_start_tvusec,false,&deadline,partial,&partialUsed));
    assert(ignoredAutoTargets==ignoredBefore&&fakeTarget[0]==3000&&fakeTarget[1]==3500);
    assert(restore(NULL));targetBusyWrites=2;targetAttempts=0;
    assert(applyTargets(NULL,mismatchTargets,14,getpid(),getuid(),p.pbi_start_tvsec,p.pbi_start_tvusec,false,&deadline,partial,&partialUsed));
    assert(targetAttempts==4&&targetBusyWrites==0);assert(restore(NULL));
    targetLagReads=3;
    assert(applyTargets(NULL,mismatchTargets,17,getpid(),getuid(),p.pbi_start_tvsec,p.pbi_start_tvusec,false,&deadline,partial,&partialUsed));
    assert(targetLagReads==0);assert(restore(NULL));
    targetBusyWrites=100;targetAttempts=0;
    assert(!applyTargets(NULL,mismatchTargets,15,getpid(),getuid(),p.pbi_start_tvsec,p.pbi_start_tvusec,false,&deadline,partial,&partialUsed));
    assert(targetAttempts==21);targetBusyWrites=0;assert(restore(NULL));
    targetPermissionDenied=true;targetAttempts=0;
    assert(!applyTargets(NULL,mismatchTargets,16,getpid(),getuid(),p.pbi_start_tvsec,p.pbi_start_tvusec,false,&deadline,partial,&partialUsed));
    assert(targetAttempts==1);targetPermissionDenied=false;assert(restore(NULL));
    rejectManualMode=true;
    assert(!applyTargets(NULL,mismatchTargets,12,getpid(),getuid(),p.pbi_start_tvsec,p.pbi_start_tvusec,false,&deadline,partial,&partialUsed));
    rejectManualMode=false;assert(restore(NULL));rejectSecondTarget=true;
    assert(!applyTargets(NULL,mismatchTargets,13,getpid(),getuid(),p.pbi_start_tvsec,p.pbi_start_tvusec,false,&deadline,partial,&partialUsed));
    rejectSecondTarget=false;assert(restore(NULL));assert(fakeMode[0]==0&&fakeMode[1]==0&&targetZeroCalls==0);
    hasFtst=true;fakeMode[0]=fakeMode[1]=0;modeBusyWrites[0]=3;modeAttempts[0]=modeAttempts[1]=0;
    double beforeMode=-1;assert(fakeRead("F0md",&beforeMode)&&beforeMode==0);
    assert(applyTargets(NULL,mismatchTargets,18,getpid(),getuid(),p.pbi_start_tvsec,p.pbi_start_tvusec,false,&deadline,partial,&partialUsed));
    assert(modeAttempts[0]==4&&modeAttempts[1]==1);assert(restore(NULL));
    modeBusyWrites[0]=1000;modeAttempts[0]=0;
    assert(!applyTargets(NULL,mismatchTargets,19,getpid(),getuid(),p.pbi_start_tvsec,p.pbi_start_tvusec,false,&deadline,partial,&partialUsed));
    assert(modeAttempts[0]==121&&!strcmp(testErrorStage,"mode_write_timeout"));modeBusyWrites[0]=0;assert(restore(NULL));
    modePermissionDenied=true;modeAttempts[0]=0;
    assert(!applyTargets(NULL,mismatchTargets,20,getpid(),getuid(),p.pbi_start_tvsec,p.pbi_start_tvusec,false,&deadline,partial,&partialUsed));
    assert(modeAttempts[0]==1&&!strcmp(testErrorStage,"mode_write"));modePermissionDenied=false;assert(restore(NULL));
    modeReadbackWrong=true;
    assert(!applyTargets(NULL,mismatchTargets,21,getpid(),getuid(),p.pbi_start_tvsec,p.pbi_start_tvusec,false,&deadline,partial,&partialUsed));
    assert(!strcmp(testErrorStage,"mode_final_readback"));modeReadbackWrong=false;assert(restore(NULL));
    // Firmware may expose manual mode only after target acceptance: no intervening mode read.
    modeNeedsTarget=true;fakeMode[0]=fakeMode[1]=0;
    assert(applyTargets(NULL,mismatchTargets,23,getpid(),getuid(),p.pbi_start_tvsec,p.pbi_start_tvusec,false,&deadline,partial,&partialUsed));
    assert(fakeMode[0]==1&&fakeMode[1]==1);modeNeedsTarget=false;assert(restore(NULL));
    modeLagReads=4;targetLagReads=4;
    assert(applyTargets(NULL,mismatchTargets,24,getpid(),getuid(),p.pbi_start_tvsec,p.pbi_start_tvusec,false,&deadline,partial,&partialUsed));assert(restore(NULL));
    // Writing fan 1 may cause the system to reclaim fan 0: verify all pairs together.
    overrideOnce=true;modeAttempts[0]=modeAttempts[1]=0;
    assert(applyTargets(NULL,mismatchTargets,25,getpid(),getuid(),p.pbi_start_tvsec,p.pbi_start_tvusec,false,&deadline,partial,&partialUsed));
    assert(modeAttempts[0]==2&&modeAttempts[1]==2);assert(restore(NULL));
    overrideAlways=true;modeAttempts[0]=modeAttempts[1]=0;
    assert(!applyTargets(NULL,mismatchTargets,26,getpid(),getuid(),p.pbi_start_tvsec,p.pbi_start_tvusec,false,&deadline,partial,&partialUsed));
    assert(modeAttempts[0]==3&&modeAttempts[1]==3&&!strcmp(testErrorStage,"mode_final_readback"));overrideAlways=false;assert(restore(NULL));
    unknownMode=7;modeAttempts[0]=0;
    assert(!applyTargets(NULL,mismatchTargets,27,getpid(),getuid(),p.pbi_start_tvsec,p.pbi_start_tvusec,false,&deadline,partial,&partialUsed));
    assert(modeAttempts[0]==1&&!strcmp(testErrorStage,"mode_unknown"));unknownMode=0;assert(restore(NULL));
    readPermissionDenied=true;modeAttempts[0]=0;
    assert(!applyTargets(NULL,mismatchTargets,28,getpid(),getuid(),p.pbi_start_tvsec,p.pbi_start_tvusec,false,&deadline,partial,&partialUsed));
    assert(modeAttempts[0]==1&&!strcmp(testErrorStage,"mode_read"));readPermissionDenied=false;assert(restore(NULL));
    // One 16-second budget covers BOTH fans, rather than restarting a 12-second mode budget per fan.
    testNow=100;deadline=1000;modeBusySeconds=1;modeBusyWrites[0]=modeBusyWrites[1]=10;modeAttempts[0]=modeAttempts[1]=0;
    assert(!applyTargets(NULL,mismatchTargets,22,getpid(),getuid(),p.pbi_start_tvsec,p.pbi_start_tvusec,false,&deadline,partial,&partialUsed));
    assert(testNow==116&&modeAttempts[0]==11&&modeAttempts[1]==6&&!strcmp(testErrorStage,"handoff_budget_expired"));
    modeBusyWrites[0]=modeBusyWrites[1]=0;modeBusySeconds=0;assert(restore(NULL));testNow=0;deadline=now()+10;
    testSkipPump=false;testSkipWait=false;
    fflush(stdout);
    // Use the real IPC lease loop with a socketpair, mocked SMC, and actual parent identity.
    // No Authorization Services prompt and no hardware operations occur.
    int sockets[2],resultPipe[2];assert(socketpair(AF_UNIX,SOCK_STREAM,0,sockets)==0);assert(pipe(resultPipe)==0);
    pid_t parent=getpid(),child=fork();assert(child>=0);
    if(child==0){
        injectedHeartbeatFD=dup(sockets[0]);testNow=100;
        close(sockets[0]);close(resultPipe[0]);dup2(sockets[1],0);dup2(sockets[1],1);close(sockets[1]);setbuf(stdout,NULL);
        hasFtst=true;restoreGlobalLag=3;restoreModeLag=4;runLease(NULL,parent,getuid(),p.pbi_start_tvsec,p.pbi_start_tvusec);
        char result=(fakeMode[0]==0&&fakeMode[1]==0&&fakeTarget[0]==3400&&fakeTarget[1]==3700)?'Y':'N';
        assert(write(resultPipe[1],&result,1)==1);_exit(0);
    }
    close(sockets[1]);close(resultPipe[1]);char b;char line[64];int n=0;
    do{assert(read(sockets[0],&b,1)==1);line[n++]=b;}while(b!='\n');line[n]=0;assert(!strcmp(line,"READY\n"));
    const char *commands[]={"SET 1 0=3000 1=3500\n","SET 2 0=3200 1=3600\n","SET 3 0=3300 1=3650\n","SET 4 0=3400 1=3700\n"};
    const char *replies[]={"ACK 1 TARGETS 0=3000.00 1=3500.00\n","ACK 2 TARGETS 0=3200.00 1=3600.00\n","ACK 3 TARGETS 0=3300.00 1=3650.00\n","ACK 4 TARGETS 0=3400.00 1=3700.00\n"};
    for(int i=0;i<4;i++) {
        assert(write(sockets[0],commands[i],strlen(commands[i]))==(ssize_t)strlen(commands[i]));n=0;
        do{assert(read(sockets[0],&b,1)==1);line[n++]=b;}while(b!='\n');line[n]=0;assert(!strcmp(line,replies[i]));
    }
    close(sockets[0]); // EOF must restore without an explicit S command.
    assert(read(resultPipe[0],&b,1)==1&&b=='Y');close(resultPipe[0]);int status;waitpid(child,&status,0);assert(WIFEXITED(status)&&WEXITSTATUS(status)==0);
    assert(socketpair(AF_UNIX,SOCK_STREAM,0,sockets)==0);child=fork();assert(child>=0);
    if(child==0){close(sockets[0]);dup2(sockets[1],0);dup2(sockets[1],1);close(sockets[1]);setbuf(stdout,NULL);runLease(NULL,parent,getuid(),p.pbi_start_tvsec,p.pbi_start_tvusec);_exit(0);}
    close(sockets[1]);n=0;do{assert(read(sockets[0],&b,1)==1);line[n++]=b;}while(b!='\n');
    assert(write(sockets[0],"SYSTEM 99\n",10)==10);n=0;
    do{assert(read(sockets[0],&b,1)==1);line[n++]=b;}while(b!='\n');line[n]=0;assert(!strcmp(line,"ACK 99 SYSTEM\n"));
    assert(read(sockets[0],&b,1)==0);close(sockets[0]);waitpid(child,&status,0);assert(WIFEXITED(status)&&WEXITSTATUS(status)==0);
    // Sleep callback only requests stop. The lease loop restores before acknowledging,
    // and a failed restore returns false so the service retains its dirty marker.
    for(int fail=0;fail<2;fail++) {
        assert(socketpair(AF_UNIX,SOCK_STREAM,0,sockets)==0);assert(pipe(resultPipe)==0);child=fork();assert(child>=0);
        if(child==0) {
            close(sockets[0]);close(resultPipe[0]);dup2(sockets[1],0);dup2(sockets[1],1);close(sockets[1]);setbuf(stdout,NULL);
            hasFtst=true;restoreGlobalLag=3;restoreModeLag=4;fakeMode[0]=fakeMode[1]=0;failFirstRestore=fail;expectSleepRestore=!fail;
            sleepOnTarget=true;sleepAcked=false;testSleepRequested=false;testSleepAcknowledge=acknowledgeSleepMock;
            bool restored=runLease(NULL,parent,getuid(),p.pbi_start_tvsec,p.pbi_start_tvusec);
            char result=(sleepAcked&&restored==!fail)?'Y':'N';assert(write(resultPipe[1],&result,1)==1);_exit(0);
        }
        close(sockets[1]);close(resultPipe[1]);n=0;do{assert(read(sockets[0],&b,1)==1);line[n++]=b;}while(b!='\n');
        const char *command="SET 70 0=3000 1=3500\n";assert(write(sockets[0],command,strlen(command))==(ssize_t)strlen(command));
        assert(read(resultPipe[0],&b,1)==1&&b=='Y');close(resultPipe[0]);close(sockets[0]);waitpid(child,&status,0);assert(WIFEXITED(status)&&WEXITSTATUS(status)==0);
    }
    // A second independent open cannot acquire the same held advisory lock.
    char path[]="/private/tmp/statelite-fan-test.XXXXXX";int a=mkstemp(path);assert(a>=0);int c=open(path,O_RDWR);
    assert(flock(a,LOCK_EX|LOCK_NB)==0);assert(flock(c,LOCK_EX|LOCK_NB)!=0);close(c);close(a);unlink(path);
    puts("Fan helper tests passed: renewable lease, bounds/exact IDs, mode 3 restoration, manual-before-target regression/partial failure, readback mismatch, IPC repeated SET/SYSTEM/EOF, exclusive lock. No hardware writes.");
}
