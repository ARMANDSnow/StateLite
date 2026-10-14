// Included by FanBridge.c. This side never writes privileged installation files.
#include <Security/SecCode.h>
#include <sys/stat.h>
#include <sys/un.h>
#define SL_SERVICE_MANIFEST "/Library/PrivilegedHelperTools/local.dingyuxuan.StateLite.FanHelper.plist"
#define SL_SERVICE_SOCKET "/private/var/run/local.dingyuxuan.StateLite.fan.sock"
static _Thread_local char clientServiceError[1024];
const char *SLFanLastServiceError(void) { return clientServiceError; }

static bool clientSecureFile(const char *path, struct stat *st) {
    return lstat(path,st)==0 && S_ISREG(st->st_mode) && st->st_uid==0 && !(st->st_mode&022);
}
static CFStringRef clientCodeHash(SecCodeRef code) {
    CFDictionaryRef info=NULL;
    if(SecCodeCopySigningInformation(code,kSecCSSigningInformation,&info))return NULL;
    CFDataRef data=CFDictionaryGetValue(info,kSecCodeInfoUnique);
    CFStringRef result=NULL;
    if(data && CFGetTypeID(data)==CFDataGetTypeID() && CFDataGetLength(data)>0 && CFDataGetLength(data)<=64) {
        char hex[129];CFIndex n=CFDataGetLength(data);const UInt8 *bytes=CFDataGetBytePtr(data);
        for(CFIndex i=0;i<n;i++)snprintf(hex+2*i,3,"%02x",bytes[i]);
        result=CFStringCreateWithCString(NULL,hex,kCFStringEncodingASCII);
    }
    CFRelease(info);return result;
}
int SLFanHelperInstallationState(const char *path) {
    struct stat directory,st;
    const char *parents[]={"/Library","/Library/PrivilegedHelperTools"};
    for(unsigned i=0;i<2;i++) {
        if(lstat(parents[i],&directory))return errno==ENOENT?1:-71001;
        if(!S_ISDIR(directory.st_mode)||directory.st_uid!=0||(directory.st_mode&022))return -71001;
    }
    if(lstat(SL_SERVICE_MANIFEST,&st))return errno==ENOENT?1:-71001;
    if(!clientSecureFile(SL_SERVICE_MANIFEST,&st)||st.st_size<=0||st.st_size>16384)return -71001;
    int input=open(SL_SERVICE_MANIFEST,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
    struct stat opened;
    if(input<0)return -71001;
    if(fstat(input,&opened)||opened.st_ino!=st.st_ino||opened.st_dev!=st.st_dev){close(input);return -71001;}
    UInt8 bytes[16384];ssize_t count=read(input,bytes,sizeof(bytes));close(input);
    if(count!=st.st_size)return -71001;
    CFDataRef data=CFDataCreate(NULL,bytes,count);
    CFPropertyListRef plist=CFPropertyListCreateWithData(NULL,data,kCFPropertyListImmutable,NULL,NULL);CFRelease(data);
    if(!plist||CFGetTypeID(plist)!=CFDictionaryGetTypeID()){if(plist)CFRelease(plist);return -71001;}
    CFDictionaryRef config=(CFDictionaryRef)plist;int version=0,serviceVersion=0;int64_t uid=-1;
    CFTypeRef v=CFDictionaryGetValue(config,CFSTR("protocolVersion"));
    CFTypeRef sv=CFDictionaryGetValue(config,CFSTR("serviceVersion"));
    CFTypeRef u=CFDictionaryGetValue(config,CFSTR("clientUID"));
    CFTypeRef expected=CFDictionaryGetValue(config,CFSTR("clientCDHash"));
    CFTypeRef helperExpected=CFDictionaryGetValue(config,CFSTR("helperCDHash"));
    bool shape=v&&sv&&u&&expected&&helperExpected&&CFGetTypeID(v)==CFNumberGetTypeID()&&CFGetTypeID(sv)==CFNumberGetTypeID()&&CFGetTypeID(u)==CFNumberGetTypeID()&&CFGetTypeID(expected)==CFStringGetTypeID()&&CFGetTypeID(helperExpected)==CFStringGetTypeID();
    if(shape){CFNumberGetValue(v,kCFNumberIntType,&version);CFNumberGetValue(sv,kCFNumberIntType,&serviceVersion);CFNumberGetValue(u,kCFNumberSInt64Type,&uid);}
    SecCodeRef self=NULL;CFStringRef actual=NULL,helperActual=NULL;
    if(!SecCodeCopySelf(kSecCSDefaultFlags,&self)){actual=clientCodeHash(self);CFRelease(self);}
    CFURLRef url=path?CFURLCreateFromFileSystemRepresentation(NULL,(const UInt8*)path,strlen(path),false):NULL;
    SecStaticCodeRef helper=NULL;
    if(url&&!SecStaticCodeCreateWithPath(url,kSecCSDefaultFlags,&helper)){helperActual=clientCodeHash((SecCodeRef)helper);CFRelease(helper);}
    if(url)CFRelease(url);
    int result=shape&&version==1&&serviceVersion==1&&uid==getuid()&&actual&&helperActual&&CFEqual(expected,actual)&&CFEqual(helperExpected,helperActual)?0:2;
    if(actual)CFRelease(actual);if(helperActual)CFRelease(helperActual);CFRelease(plist);return result;
}
static int clientRunInstaller(const char *path,const char *action,const char *success) {
    clientServiceError[0]=0;
    int fd=-1,status=SLFanAuthorizeAction(path,action,&fd);if(status)return status;
    struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);double until=t.tv_sec+t.tv_nsec/1e9+45;
    char line[1024];size_t used=0;int result=-71002;
    while(1) {
        clock_gettime(CLOCK_MONOTONIC,&t);if(t.tv_sec+t.tv_nsec/1e9>=until)break;
        char b;int r=SLFanReceive(fd,&b,500);if(r<0)break;if(!r)continue;
        if(b=='\n'){line[used]=0;if(!strcmp(line,success))result=0;else strlcpy(clientServiceError,line,sizeof(clientServiceError));break;}
        if(used>=sizeof(line)-1)break;line[used++]=b;
    }
    if(result && !clientServiceError[0])strlcpy(clientServiceError,"安装器未返回完成确认",sizeof(clientServiceError));
    SLFanDisconnect(fd);return result;
}
static int clientConnectService(int *fd) {
    struct stat st;
    if(lstat(SL_SERVICE_SOCKET,&st)||!S_ISSOCK(st.st_mode)||st.st_uid!=0)return -71003;
    int channel=socket(AF_UNIX,SOCK_STREAM,0);if(channel<0)return -71003;
    int flags=fcntl(channel,F_GETFL);
    if(flags<0||fcntl(channel,F_SETFL,flags|O_NONBLOCK)){close(channel);return -71003;}
    struct sockaddr_un address={0};address.sun_family=AF_UNIX;
    strlcpy(address.sun_path,SL_SERVICE_SOCKET,sizeof(address.sun_path));
    if(connect(channel,(struct sockaddr*)&address,sizeof(address))) {
        if(errno!=EINPROGRESS){close(channel);return -71003;}
        struct pollfd waiting={.fd=channel,.events=POLLOUT};
        int error=0;socklen_t size=sizeof(error);
        if(poll(&waiting,1,200)<=0||getsockopt(channel,SOL_SOCKET,SO_ERROR,&error,&size)||error){close(channel);return -71003;}
    }
    uid_t uid;gid_t gid;
    if(getpeereid(channel,&uid,&gid)||uid!=0){close(channel);return -71004;}
    int enabled=1;setsockopt(channel,SOL_SOCKET,SO_NOSIGPIPE,&enabled,sizeof(enabled));
    fcntl(channel,F_SETFD,FD_CLOEXEC);*fd=channel;return 0;
}
int SLFanLaunchHelper(const char *path,int *fd) {
    clientServiceError[0]=0;
    if(!fd)return -71001;*fd=-1;
    int state=SLFanHelperInstallationState(path);
    if(state<0)return state;
    if(state!=0) {
        int result=clientRunInstaller(path,"--install","INSTALLED");if(result)return result;
        if(SLFanHelperInstallationState(path)!=0)return -71005;
    }
    struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);double until=t.tv_sec+t.tv_nsec/1e9+3;
    for(int attempt=0;attempt<30;attempt++) {
        int result=clientConnectService(fd);if(!result)return 0;
        clock_gettime(CLOCK_MONOTONIC,&t);if(t.tv_sec+t.tv_nsec/1e9>=until)break;
        usleep(100000);
    }
    return -71003;
}
int SLFanRemoveInstalledHelper(const char *path) {
    return clientRunInstaller(path,"--uninstall","UNINSTALLED");
}
