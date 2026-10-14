// Included by FanHelper.c after the hardware/lease implementation.
// Privilege is installed once; the service accepts only a pinned running client.
#include <Security/Security.h>
#include <CoreFoundation/CoreFoundation.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <spawn.h>
#include <launch.h>
#include <bsm/libbsm.h>
#include <poll.h>

#define SL_SERVICE_LABEL "local.dingyuxuan.StateLite.FanHelper"
#define SL_SERVICE_DIR "/Library/PrivilegedHelperTools"
#define SL_SERVICE_BIN SL_SERVICE_DIR "/" SL_SERVICE_LABEL
#define SL_SERVICE_CONFIG SL_SERVICE_BIN ".plist"
#define SL_SERVICE_DIRTY SL_SERVICE_BIN ".dirty"
#define SL_SERVICE_JOB "/Library/LaunchDaemons/" SL_SERVICE_LABEL ".plist"
#define SL_SERVICE_SOCKET "/private/var/run/local.dingyuxuan.StateLite.fan.sock"
#define SL_SERVICE_LOCK "/private/var/run/statelite-fan.lock"

static bool slsHardened(CFDictionaryRef info) {
    CFTypeRef flags=CFDictionaryGetValue(info,kSecCodeInfoFlags);uint32_t value=0;
    if(!flags||CFGetTypeID(flags)!=CFNumberGetTypeID()||
       !CFNumberGetValue(flags,kCFNumberSInt32Type,&value)||!(value&kSecCodeSignatureRuntime))return false;
    CFTypeRef entitlements=CFDictionaryGetValue(info,kSecCodeInfoEntitlementsDict);
    if(!entitlements)return true;
    if(CFGetTypeID(entitlements)!=CFDictionaryGetTypeID())return false;
    const CFStringRef forbidden[]={
        CFSTR("com.apple.security.cs.allow-dyld-environment-variables"),
        CFSTR("com.apple.security.cs.disable-library-validation"),
        CFSTR("com.apple.security.get-task-allow"),CFSTR("get-task-allow"),
        CFSTR("com.apple.security.cs.allow-unsigned-executable-memory"),
        CFSTR("com.apple.security.cs.disable-executable-page-protection"),
        CFSTR("com.apple.security.cs.allow-jit")
    };
    for(size_t i=0;i<sizeof(forbidden)/sizeof(forbidden[0]);i++) {
        CFTypeRef setting=CFDictionaryGetValue(entitlements,forbidden[i]);
        // An exception is accepted only when explicitly Boolean false.
        if(setting&&(CFGetTypeID(setting)!=CFBooleanGetTypeID()||CFBooleanGetValue(setting)))return false;
    }
    return true;
}
static bool slsRootPath(const char *path,bool directory) {
    struct stat s;
    return lstat(path,&s)==0 && s.st_uid==0 && !(s.st_mode&022) &&
        (directory?S_ISDIR(s.st_mode):S_ISREG(s.st_mode));
}
static bool slsRuntimeDirectoryStat(const struct stat *s) {
    // macOS ships /private/var/run as root:daemon (gid 1), mode 0775.
    // This exception is restricted to that exact OS directory and system group.
    return S_ISDIR(s->st_mode)&&s->st_uid==0&&!(s->st_mode&S_IWOTH)&&
        (!(s->st_mode&S_IWGRP)||s->st_gid==1);
}
static bool slsRuntimeDirectory(void) {
    struct stat s;
    return lstat("/private/var/run",&s)==0&&slsRuntimeDirectoryStat(&s);
}
static bool slsDirectories(void) {
    if(!slsRootPath("/Library",true)||!slsRootPath("/private",true)||
       !slsRootPath("/private/var",true)||!slsRuntimeDirectory())return false;
    if(mkdir(SL_SERVICE_DIR,0755)&&errno!=EEXIST)return false;
    return slsRootPath(SL_SERVICE_DIR,true)&&slsRootPath("/Library/LaunchDaemons",true);
}
static bool slsHashInfo(SecCodeRef code,char result[129]) {
    if(SecCodeCheckValidity(code,kSecCSStrictValidate,NULL))return false;
    CFDictionaryRef info=NULL;
    if(SecCodeCopySigningInformation(code,kSecCSSigningInformation,&info))return false;
    CFDataRef data=CFDictionaryGetValue(info,kSecCodeInfoUnique);
    CFIndex n=data&&CFGetTypeID(data)==CFDataGetTypeID()?CFDataGetLength(data):0;
    bool ok=slsHardened(info)&&n>0&&n<=64;
    if(ok){const UInt8 *bytes=CFDataGetBytePtr(data);for(CFIndex i=0;i<n;i++)sprintf(result+i*2,"%02x",bytes[i]);result[n*2]=0;}
    CFRelease(info);return ok;
}
static bool slsDynamicHash(pid_t pid,const audit_token_t *token,char out[129]) {
    CFMutableDictionaryRef attrs=CFDictionaryCreateMutable(NULL,0,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    if(!attrs)return false;
    CFTypeRef value=token?(CFTypeRef)CFDataCreate(NULL,(const UInt8 *)token,sizeof(*token)):
        (CFTypeRef)CFNumberCreate(NULL,kCFNumberIntType,&pid);
    if(!value){CFRelease(attrs);return false;}
    CFDictionarySetValue(attrs,token?kSecGuestAttributeAudit:kSecGuestAttributePid,value);
    SecCodeRef code=NULL;bool ok=SecCodeCopyGuestWithAttributes(NULL,attrs,kSecCSDefaultFlags,&code)==0;
    if(ok)ok=slsHashInfo(code,out);
    if(code)CFRelease(code);CFRelease(value);CFRelease(attrs);return ok;
}
static bool slsStaticHash(const char *path,char out[129]) {
    CFURLRef url=CFURLCreateFromFileSystemRepresentation(NULL,(const UInt8 *)path,strlen(path),false);
    SecStaticCodeRef code=NULL;CFDictionaryRef info=NULL;bool ok=false;
    if(url&&!SecStaticCodeCreateWithPath(url,0,&code)&&!SecStaticCodeCheckValidity(code,kSecCSStrictValidate,NULL)&&
       !SecCodeCopySigningInformation(code,kSecCSSigningInformation,&info)) {
        CFDataRef d=CFDictionaryGetValue(info,kSecCodeInfoUnique);
        CFIndex n=d&&CFGetTypeID(d)==CFDataGetTypeID()?CFDataGetLength(d):0;
        if(slsHardened(info)&&n>0&&n<=64){const UInt8 *b=CFDataGetBytePtr(d);for(CFIndex i=0;i<n;i++)sprintf(out+i*2,"%02x",b[i]);out[n*2]=0;ok=true;}
    }
    if(info)CFRelease(info);if(code)CFRelease(code);if(url)CFRelease(url);return ok;
}
static bool slsWriteAll(int fd,const void *data,size_t n) {
    const char *p=data;while(n){ssize_t k=write(fd,p,n);if(k<0&&errno==EINTR)continue;if(k<=0)return false;p+=k;n-=k;}return true;
}
static bool slsWriteFile(const char *path,const void *data,size_t size,mode_t mode) {
    int fd=open(path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,mode);
    if(fd<0)return false;
    bool ok=fchmod(fd,mode)==0&&fchown(fd,0,0)==0&&slsWriteAll(fd,data,size)&&fsync(fd)==0;
    close(fd);if(!ok)unlink(path);return ok;
}
static CFDictionaryRef slsManifest(void) {
    int fd=open(SL_SERVICE_CONFIG,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);struct stat st;
    if(fd<0)return NULL;
    if(fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_uid!=0||(st.st_mode&022)||st.st_size<=0||st.st_size>8192){close(fd);return NULL;}
    char bytes[8192];size_t used=0;
    while(used<(size_t)st.st_size){ssize_t n=read(fd,bytes+used,(size_t)st.st_size-used);if(n<0&&errno==EINTR)continue;if(n<=0)break;used+=n;}
    close(fd);if(used!=(size_t)st.st_size)return NULL;
    CFDataRef data=CFDataCreate(NULL,(UInt8 *)bytes,used);
    CFPropertyListRef p=CFPropertyListCreateWithData(NULL,data,kCFPropertyListImmutable,NULL,NULL);CFRelease(data);
    if(!p||CFGetTypeID(p)!=CFDictionaryGetTypeID()){if(p)CFRelease(p);return NULL;}return p;
}
static bool slsManifestString(CFDictionaryRef d,CFStringRef key,char out[129]) {
    CFTypeRef v=CFDictionaryGetValue(d,key);
    return v&&CFGetTypeID(v)==CFStringGetTypeID()&&CFStringGetCString(v,out,129,kCFStringEncodingUTF8);
}
static bool slsManifestNumber(CFDictionaryRef d,CFStringRef key,long long *out) {
    CFTypeRef v=CFDictionaryGetValue(d,key);
    return v&&CFGetTypeID(v)==CFNumberGetTypeID()&&CFNumberGetValue(v,kCFNumberLongLongType,out);
}
static int slsLock(void) {
    int fd=open(SL_SERVICE_LOCK,O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC,0600);struct stat st;
    if(fd<0)return -1;
    struct stat named;
    if(fstat(fd,&st)||!S_ISREG(st.st_mode)||st.st_uid!=0||(st.st_mode&077)||st.st_nlink!=1||
       flock(fd,LOCK_EX|LOCK_NB)||lstat(SL_SERVICE_LOCK,&named)||!S_ISREG(named.st_mode)||
       named.st_dev!=st.st_dev||named.st_ino!=st.st_ino){close(fd);return -1;}return fd;
}
static int slsLaunchctl(const char *verb,const char *arg) {
    pid_t child;char *argv[]={"/bin/launchctl",(char *)verb,"system",(char *)arg,NULL};
    char *environment[]={"PATH=/usr/bin:/bin:/usr/sbin:/sbin",NULL};
    posix_spawn_file_actions_t actions;if(posix_spawn_file_actions_init(&actions))return EIO;
    int e=posix_spawn_file_actions_adddup2(&actions,STDERR_FILENO,STDOUT_FILENO);
    if(!e)e=posix_spawn(&child,argv[0],&actions,NULL,argv,environment);
    posix_spawn_file_actions_destroy(&actions);if(e)return e;
    int status;while(waitpid(child,&status,0)<0){if(errno!=EINTR)return errno;}
    return WIFEXITED(status)?WEXITSTATUS(status):128;
}
static bool slsRecover(void) {
    struct stat st;if(lstat(SL_SERVICE_DIRTY,&st))return errno==ENOENT;
    if(!S_ISREG(st.st_mode)||st.st_uid!=0||(st.st_mode&077))return false;
    SLFanConnection *c=SLFanOpen();if(!c)return false;
    bool ok=discover(c)&&restore(c);SLFanClose(c);
    return ok&&unlink(SL_SERVICE_DIRTY)==0;
}
static bool slsAdminCaller(int argc,char **argv,uid_t *uid,char hash[129]) {
    if(argc!=6||geteuid()!=0)return false;
    char *end;errno=0;long p=strtol(argv[2],&end,10);if(errno||*end||p<=1||p>INT_MAX)return false;
    unsigned long u=strtoul(argv[3],&end,10);if(errno||*end||u==0||u>UINT32_MAX)return false;
    unsigned long long sec=strtoull(argv[4],&end,10);if(errno||*end)return false;
    unsigned long long usec=strtoull(argv[5],&end,10);if(errno||*end||usec>=1000000)return false;
    *uid=(uid_t)u;
    return parentMatches((pid_t)p,*uid,sec,usec)&&verifyParentImage((pid_t)p)&&slsDynamicHash((pid_t)p,NULL,hash)&&parentMatches((pid_t)p,*uid,sec,usec);
}
static bool slsCopySelf(const char *target,char ownHash[129]) {
    char own[PROC_PIDPATHINFO_MAXSIZE];uint32_t cap=sizeof(own);
    if(_NSGetExecutablePath(own,&cap)||!slsDynamicHash(getpid(),NULL,ownHash))return false;
    int input=open(own,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);struct stat st;
    if(input<0)return false;
    if(fstat(input,&st)||!S_ISREG(st.st_mode)||st.st_size<=0||st.st_size>16*1024*1024){close(input);return false;}
    int output=open(target,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0755);
    if(output<0){close(input);return false;}
    char bytes[65536];bool ok=true;off_t copied=0;
    while(ok){ssize_t n=read(input,bytes,sizeof(bytes));if(n<0&&errno==EINTR)continue;if(n<0){ok=false;break;}if(!n)break;copied+=n;if(copied>st.st_size){ok=false;break;}ok=slsWriteAll(output,bytes,n);}
    ok=ok&&copied==st.st_size&&fchown(output,0,0)==0&&fchmod(output,0755)==0&&fsync(output)==0;
    close(input);close(output);char copiedHash[129];
    return ok&&slsStaticHash(target,copiedHash)&&!strcmp(ownHash,copiedHash);
}
static int slsInstall(int argc,char **argv,bool remove) {
    uid_t uid;char clientHash[129];
    if(!slsAdminCaller(argc,argv,&uid,clientHash)){puts("ERROR 0 stage=service_install_identity");return 65;}
    if(!slsDirectories()){puts("ERROR 0 stage=service_install_directories");return 66;}
    // A socket-activated worker may still be completing its short idle window.
    // Wait past that window, but never interrupt a live lease to install/remove.
    int lock=-1;for(int i=0;i<45&&lock<0;i++){lock=slsLock();if(lock<0)usleep(100000);}
    if(lock<0){puts("ERROR 0 stage=service_busy");return 68;}
    if(!slsRecover()){close(lock);puts("ERROR 0 stage=service_recovery_failed");return 69;}
    const char *paths[]={SL_SERVICE_BIN,SL_SERVICE_CONFIG,SL_SERVICE_JOB};
    bool existed[3]={false,false,false};
    for(int i=0;i<3;i++){struct stat st;if(!lstat(paths[i],&st)){if(!slsRootPath(paths[i],false)){printf("ERROR 0 stage=service_existing_file_unsafe index=%d\n",i);close(lock);return 70;}existed[i]=true;}else if(errno!=ENOENT){printf("ERROR 0 stage=service_existing_file_stat index=%d errno=%d\n",i,errno);close(lock);return 70;}}
    if(remove){
        if(existed[2]&&slsLaunchctl("bootout",SL_SERVICE_JOB)!=0){close(lock);puts("ERROR 0 stage=service_bootout");return 71;}
        bool ok=true;for(int i=2;i>=0;i--)if(existed[i]&&unlink(paths[i]))ok=false;
        close(lock);puts(ok?"UNINSTALLED":"ERROR 0 stage=service_remove");return ok?0:72;
    }
    char staging[]=SL_SERVICE_DIR "/.StateLite-install.XXXXXX";
    if(!mkdtemp(staging)){printf("ERROR 0 stage=service_staging_create errno=%d\n",errno);close(lock);return 73;}
    char fresh[3][PATH_MAX],old[3][PATH_MAX];
    for(int i=0;i<3;i++){snprintf(fresh[i],PATH_MAX,"%s/new%d",staging,i);snprintf(old[i],PATH_MAX,"%s/old%d",staging,i);}
    const char *failureStage="service_copy_self_signature";
    char ownHash[129],manifest[2048];bool ok=slsCopySelf(fresh[0],ownHash);
    int n=snprintf(manifest,sizeof(manifest),"<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>protocolVersion</key><integer>1</integer><key>serviceVersion</key><integer>1</integer><key>clientUID</key><integer>%u</integer><key>clientCDHash</key><string>%s</string><key>helperCDHash</key><string>%s</string></dict></plist>",uid,clientHash,ok?ownHash:"");
    const char job[]="<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Label</key><string>" SL_SERVICE_LABEL "</string><key>ProgramArguments</key><array><string>" SL_SERVICE_BIN "</string><string>--serve</string></array><key>RunAtLoad</key><true/><key>KeepAlive</key><dict><key>Crashed</key><true/></dict><key>Sockets</key><dict><key>Control</key><dict><key>SockPathName</key><string>" SL_SERVICE_SOCKET "</string><key>SockPathMode</key><integer>438</integer><key>SockType</key><string>stream</string></dict></dict></dict></plist>";
    if(ok){failureStage="service_manifest_write";ok=n>0&&(size_t)n<sizeof(manifest)&&slsWriteFile(fresh[1],manifest,n,0644);}
    if(ok){failureStage="service_launchdaemon_write";ok=slsWriteFile(fresh[2],job,sizeof(job)-1,0644);}
    bool backed[3]={false,false,false},placed[3]={false,false,false},unloaded=false;
    if(ok&&existed[2]){failureStage="service_existing_bootout";ok=slsLaunchctl("bootout",SL_SERVICE_JOB)==0;unloaded=ok;}
    for(int i=0;ok&&i<3;i++){if(existed[i]){failureStage="service_backup_rename";ok=rename(paths[i],old[i])==0;backed[i]=ok;}if(ok){failureStage="service_install_rename";ok=rename(fresh[i],paths[i])==0;placed[i]=ok;}}
    if(ok){failureStage="service_bootstrap";ok=slsLaunchctl("bootstrap",SL_SERVICE_JOB)==0;}
    if(!ok){
        if(placed[2])slsLaunchctl("bootout",SL_SERVICE_JOB);
        bool rollback=true;for(int i=2;i>=0;i--){if(placed[i]&&unlink(paths[i]))rollback=false;if(backed[i]&&rename(old[i],paths[i]))rollback=false;}
        if(unloaded&&existed[2]&&slsLaunchctl("bootstrap",SL_SERVICE_JOB))rollback=false;
        if(!rollback){printf("ERROR 0 stage=service_rollback original=%s recovery=%s\n",failureStage,staging);close(lock);return 74;}
    }
    for(int i=0;i<3;i++){unlink(fresh[i]);unlink(old[i]);}rmdir(staging);close(lock);
    if(ok)puts("INSTALLED");else printf("ERROR 0 stage=%s\n",failureStage);return ok?0:75;
}
static bool slsPeer(int fd,CFDictionaryRef manifest,pid_t *pid,uid_t *uid,struct proc_bsdinfo *info) {
    audit_token_t token;socklen_t length=sizeof(token);uid_t peer;gid_t group;
    if(getpeereid(fd,&peer,&group)||getsockopt(fd,SOL_LOCAL,LOCAL_PEERTOKEN,&token,&length)||length!=sizeof(token))return false;
    long long expectedUID,version;char expectedHash[129],actualHash[129];
    if(!slsManifestNumber(manifest,CFSTR("protocolVersion"),&version)||version!=1||
       !slsManifestNumber(manifest,CFSTR("clientUID"),&expectedUID)||expectedUID<=0||expectedUID!=peer||
       audit_token_to_euid(token)!=peer||!slsManifestString(manifest,CFSTR("clientCDHash"),expectedHash))return false;
    *pid=audit_token_to_pid(token);*uid=peer;
    return *pid>1&&slsDynamicHash(*pid,&token,actualHash)&&!strcmp(expectedHash,actualHash)&&
        proc_pidinfo(*pid,PROC_PIDTBSDINFO,0,info,sizeof(*info))==sizeof(*info)&&info->pbi_uid==peer;
}
static int slsServe(void) {
    if(geteuid()!=0)return 65;
    if(!slsDirectories()){fprintf(stderr,"ERROR 0 stage=service_runtime_directories\n");return 66;}
    int lock=-1;for(int i=0;i<50&&lock<0;i++){lock=slsLock();if(lock<0)usleep(100000);}if(lock<0)return 68;
    if(!slsRecover()){close(lock);return 69;}
    CFDictionaryRef manifest=slsManifest();if(!manifest){close(lock);return 70;}
    char own[129],expected[129];
    if(!slsManifestString(manifest,CFSTR("helperCDHash"),expected)||!slsDynamicHash(getpid(),NULL,own)||strcmp(own,expected)){CFRelease(manifest);close(lock);return 65;}
    int *fds=NULL;size_t count=0;
    if(launch_activate_socket("Control",&fds,&count)||count!=1){free(fds);CFRelease(manifest);close(lock);return 71;}
    int listener=fds[0];free(fds);struct pollfd p={.fd=listener,.events=POLLIN};
    int channel=-1;pid_t pid=0;uid_t uid=0;struct proc_bsdinfo info={0};
    // One short activation window; unauthenticated peers cannot enter a lease.
    for(int attempt=0;attempt<8;attempt++) {
        if(poll(&p,1,3000)<=0)break;
        int fd=accept(listener,NULL,NULL);if(fd<0)continue;
        if(slsPeer(fd,manifest,&pid,&uid,&info)){channel=fd;break;}close(fd);
    }
    CFRelease(manifest);close(listener);
    if(channel<0){close(lock);return 0;}
    int yes=1;setsockopt(channel,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes));
    if(dup2(channel,STDIN_FILENO)<0||dup2(channel,STDOUT_FILENO)<0){close(channel);close(lock);return 72;}if(channel>STDERR_FILENO)close(channel);
    setbuf(stdout,NULL);signal(SIGPIPE,SIG_IGN);
    SLFanConnection *c=SLFanOpen();bool ok=c&&discover(c);
    if(ok)ok=slsWriteFile(SL_SERVICE_DIRTY,"active\n",7,0600);
    if(ok){ok=runLease(c,pid,uid,info.pbi_start_tvsec,info.pbi_start_tvusec);if(ok)ok=unlink(SL_SERVICE_DIRTY)==0;}
    else puts("ERROR 0 stage=service_metadata_or_dirty");
    if(c)SLFanClose(c);close(lock);return ok?0:73;
}
static bool slsPreflightCopy(const char *source,const char *expected) {
    char directory[]="/private/tmp/statelite-preflight.XXXXXX";
    if(!mkdtemp(directory))return false;
    char path[PATH_MAX];snprintf(path,sizeof(path),"%s/FanHelper",directory);
    int in=open(source,O_RDONLY|O_NOFOLLOW|O_CLOEXEC),out=-1;struct stat st;
    bool ok=in>=0&&fstat(in,&st)==0&&S_ISREG(st.st_mode)&&st.st_size>0&&st.st_size<=16*1024*1024;
    if(ok){out=open(path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0700);ok=out>=0;}
    char buffer[65536];off_t copied=0;
    while(ok){ssize_t n=read(in,buffer,sizeof(buffer));if(n<0&&errno==EINTR)continue;if(n<0){ok=false;break;}if(!n)break;copied+=n;if(copied>st.st_size){ok=false;break;}ok=slsWriteAll(out,buffer,n);}
    if(ok)ok=copied==st.st_size&&fsync(out)==0;
    if(in>=0)close(in);if(out>=0)close(out);
    char hash[129];if(ok)ok=slsStaticHash(path,hash)&&!strcmp(hash,expected);
    if(unlink(path)&&errno!=ENOENT)ok=false;if(rmdir(directory))ok=false;
    return ok;
}
static int slsPreflight(void) {
    bool passed=true;const char *first=NULL;
#define SLS_PREFLIGHT(name, expression) do {bool good=(expression);printf("CHECK %s=%s\n",name,good?"ok":"failed");if(!good){passed=false;if(!first)first=name;}} while(0)
    pid_t parent=getppid();struct proc_bsdinfo info={0};char parentHash[129],ownHash[129],staticHash[129];
    bool parentInfo=parent>1&&proc_pidinfo(parent,PROC_PIDTBSDINFO,0,&info,sizeof(info))==sizeof(info)&&info.pbi_uid==getuid();
    SLS_PREFLIGHT("parent_process",parentInfo);
    SLS_PREFLIGHT("parent_image",parentInfo&&verifyParentImage(parent));
    SLS_PREFLIGHT("parent_signature",parentInfo&&slsDynamicHash(parent,NULL,parentHash));
    bool ownValid=slsDynamicHash(getpid(),NULL,ownHash);
    SLS_PREFLIGHT("helper_dynamic_signature",ownValid);
    char ownPath[PROC_PIDPATHINFO_MAXSIZE];uint32_t length=sizeof(ownPath);
    bool ownPathValid=_NSGetExecutablePath(ownPath,&length)==0;
    SLS_PREFLIGHT("helper_static_signature",ownValid&&ownPathValid&&slsStaticHash(ownPath,staticHash)&&!strcmp(staticHash,ownHash));
    SLS_PREFLIGHT("helper_copy_signature",ownValid&&ownPathValid&&slsPreflightCopy(ownPath,ownHash));
    SLS_PREFLIGHT("library_directory",slsRootPath("/Library",true));
    struct stat st;bool helperDirectory=lstat(SL_SERVICE_DIR,&st)==0?slsRootPath(SL_SERVICE_DIR,true):errno==ENOENT;
    SLS_PREFLIGHT("helper_directory",helperDirectory);
    SLS_PREFLIGHT("launchdaemon_directory",slsRootPath("/Library/LaunchDaemons",true));
    SLS_PREFLIGHT("runtime_parent_directories",slsRootPath("/private",true)&&slsRootPath("/private/var",true));
    SLS_PREFLIGHT("runtime_directory",slsRuntimeDirectory());
    const char *paths[]={SL_SERVICE_BIN,SL_SERVICE_CONFIG,SL_SERVICE_JOB};bool installedPaths=true;
    for(int i=0;i<3;i++)if(lstat(paths[i],&st)==0){if(!slsRootPath(paths[i],false))installedPaths=false;}else if(errno!=ENOENT)installedPaths=false;
    SLS_PREFLIGHT("existing_install_paths",installedPaths);
    bool lockSafe=lstat(SL_SERVICE_LOCK,&st)==0?S_ISREG(st.st_mode)&&st.st_uid==0&&!(st.st_mode&077)&&st.st_nlink==1:errno==ENOENT;
    SLS_PREFLIGHT("existing_lock",lockSafe);
    if(passed)puts("PREFLIGHT_OK");else printf("ERROR 0 stage=preflight_%s\n",first);
#undef SLS_PREFLIGHT
    return passed?0:65;
}
int SLFanServiceCommand(int argc,char **argv) {
    if(argc<2)return -1;
    if(!strcmp(argv[1],"--preflight"))return argc==2?slsPreflight():64;
    if(!strcmp(argv[1],"--install"))return slsInstall(argc,argv,false);
    if(!strcmp(argv[1],"--uninstall"))return slsInstall(argc,argv,true);
    if(!strcmp(argv[1],"--serve"))return argc==2?slsServe():64;
    return -1;
}
