// Authentication tests only: no root writes, launchctl or SMC access.
#define SL_FAN_HELPER 1
#include "../Sources/FanBridge.c"
#include <assert.h>
#include <stdio.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <fcntl.h>
#include <libproc.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <mach-o/dyld.h>
static bool discover(SLFanConnection *c){(void)c;abort();}
static bool restore(SLFanConnection *c){(void)c;abort();}
static bool runLease(SLFanConnection*c,pid_t p,uid_t u,unsigned long long s,unsigned long long us){(void)c;(void)p;(void)u;(void)s;(void)us;abort();}
static bool parentMatches(pid_t p,uid_t u,unsigned long long s,unsigned long long us){(void)p;(void)u;(void)s;(void)us;return false;}
static bool verifyParentImage(pid_t p){(void)p;return false;}
#include "../Sources/FanService.c"
static void number(CFMutableDictionaryRef d,CFStringRef key,long long n){CFNumberRef v=CFNumberCreate(NULL,kCFNumberLongLongType,&n);CFDictionarySetValue(d,key,v);CFRelease(v);}
static void string(CFMutableDictionaryRef d,CFStringRef key,const char*s){CFStringRef v=CFStringCreateWithCString(NULL,s,kCFStringEncodingUTF8);CFDictionarySetValue(d,key,v);CFRelease(v);}
int main(int argc,char **argv) {
    assert(geteuid()!=0); // Running this suite as root is never required.
    if(argc==2&&!strcmp(argv[1],"--expect-rejected")) {
        char rejected[129];assert(!slsDynamicHash(getpid(),NULL,rejected));
        assert(!slsStaticHash(argv[0],rejected));puts("Non-hardened or exception-entitled signature rejected");return 0;
    }
    char actual[129];assert(slsDynamicHash(getpid(),NULL,actual));
    assert(slsPreflightCopy(argv[0],actual));
    assert(slsPreflight()==65); // Stub parent is never approved; all checks still run.
    struct stat runtime={.st_mode=S_IFDIR|0775,.st_uid=0,.st_gid=1};
    assert(slsRuntimeDirectoryStat(&runtime));
    runtime.st_gid=20;assert(!slsRuntimeDirectoryStat(&runtime));
    runtime.st_gid=1;runtime.st_mode=S_IFDIR|0777;assert(!slsRuntimeDirectoryStat(&runtime));
    runtime.st_mode=S_IFLNK|0755;assert(!slsRuntimeDirectoryStat(&runtime));
    runtime.st_mode=S_IFDIR|0755;runtime.st_uid=getuid();assert(!slsRuntimeDirectoryStat(&runtime));
    runtime.st_uid=0;runtime.st_gid=0;assert(slsRuntimeDirectoryStat(&runtime));
    assert(slsRuntimeDirectory()); // Read-only check of this host's OS directory.
    char dir[]="/private/tmp/statelite-service-test.XXXXXX";assert(mkdtemp(dir));
    char path[PATH_MAX];snprintf(path,sizeof(path),"%s/control",dir);
    struct sockaddr_un addr={.sun_family=AF_UNIX};assert(strlen(path)<sizeof(addr.sun_path));strcpy(addr.sun_path,path);
    int listener=socket(AF_UNIX,SOCK_STREAM,0),client=socket(AF_UNIX,SOCK_STREAM,0);assert(listener>=0&&client>=0);
    assert(!bind(listener,(struct sockaddr*)&addr,sizeof(addr)));assert(!listen(listener,1));
    assert(!connect(client,(struct sockaddr*)&addr,sizeof(addr)));int peer=accept(listener,NULL,NULL);assert(peer>=0);
    CFMutableDictionaryRef d=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    number(d,CFSTR("protocolVersion"),1);number(d,CFSTR("clientUID"),getuid());string(d,CFSTR("clientCDHash"),actual);
    pid_t pid;uid_t uid;struct proc_bsdinfo info;
    assert(slsPeer(peer,d,&pid,&uid,&info)&&pid==getpid()&&uid==getuid());
    string(d,CFSTR("clientCDHash"),"0000000000000000000000000000000000000000");assert(!slsPeer(peer,d,&pid,&uid,&info));
    string(d,CFSTR("clientCDHash"),actual);number(d,CFSTR("clientUID"),getuid()+1);assert(!slsPeer(peer,d,&pid,&uid,&info));
    number(d,CFSTR("clientUID"),getuid());number(d,CFSTR("protocolVersion"),2);assert(!slsPeer(peer,d,&pid,&uid,&info));
    number(d,CFSTR("protocolVersion"),1);CFDictionaryRemoveValue(d,CFSTR("clientCDHash"));assert(!slsPeer(peer,d,&pid,&uid,&info));
    string(d,CFSTR("clientCDHash"),actual);string(d,CFSTR("clientUID"),"501");assert(!slsPeer(peer,d,&pid,&uid,&info));
    CFRelease(d);close(peer);close(client);close(listener);unlink(path);rmdir(dir);
    char *none[]={"test","--unknown",NULL};assert(SLFanServiceCommand(2,none)==-1);
    char *serve[]={"test","--serve",NULL};assert(SLFanServiceCommand(2,serve)==65);
    char *install[]={"test","--install",NULL};assert(SLFanServiceCommand(2,install)==65);
    puts("FanService authentication tests passed: audit token, signature pin, UID, protocol, malformed manifest, non-root refusal");
    return 0;
}
