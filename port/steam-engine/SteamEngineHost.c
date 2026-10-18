#include "SteamEngineHost.h"
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdatomic.h>

typedef int32_t HSteamPipe,HSteamUser;
typedef struct {
    int logOn,logOff,loggedOn,logonState,connected,steamID,setLoginToken,logOnOffline,subscribed,canOffline;
} EngineMethods;
typedef struct {
    void *image,*engine,*user;
    HSteamPipe pipe;
    HSteamUser globalUser;
    EngineMethods methods;
} EngineContext;
// Failed preparation may have allocated a genuine Valve global user/pipe.
// Keep that private context for retry; never expose it as a ready engine or
// guess a destructor slot in Valve's undocumented engine interface.
static EngineContext Prepared,ActiveEngine;
static _Atomic bool EngineReady;
static pthread_mutex_t StartLock=PTHREAD_MUTEX_INITIALIZER;

static void *Slot(void *object,int slot) { return (*(void ***)object)[slot]; }
static const char *TypeName(void *object) {
    void **typeinfo=(void **)(*(void ***)object)[-1];
    return typeinfo?(const char *)typeinfo[1]:"";
}
// Each IClientUser proxy method passes its own name to the IPC call in x4
// (adrp x4 / add x4, x4, #off). Read that name; stop at the method's ret.
static const char *ProxyMethodName(void *function) {
    const uint32_t *code=(const uint32_t *)function;
    uintptr_t page=0;
    for (int i=0;i<256;i++) {
        uint32_t insn=code[i];
        if (insn==0xd65f03c0) return NULL; // ret
        if ((insn&0x9f00001f)==0x90000004) { // adrp x4
            int64_t imm=(int64_t)((((insn>>5)&0x7ffff)<<2)|((insn>>29)&3));
            if (imm&(1<<20)) imm-=1<<21;
            page=((uintptr_t)&code[i]&~(uintptr_t)0xfff)+(uintptr_t)(imm<<12);
        } else if ((insn&0xffc003ff)==0x91000084 && page) { // add x4, x4, #imm
            return (const char *)(page+((insn>>10)&0xfff));
        }
    }
    return NULL;
}
static int FindMethod(void *user,const char *name,void *image) {
    Dl_info base;
    if (!dladdr(image,&base)) return -1;
    for (int slot=0;slot<400;slot++) {
        Dl_info info;void *function=Slot(user,slot);
        if (!dladdr(function,&info) || info.dli_fbase!=base.dli_fbase) break; // end of vtable
        const char *found=ProxyMethodName(function);
        if (found && strcmp(found,name)==0) return slot;
    }
    return -1;
}
static void *Pump(void *engine) {
    for (;;) { ((void (*)(void *))Slot(engine,19))(engine);usleep(10000); } // RunFrame
    return NULL;
}
bool AgePadEngineStart(void *image,char *error,unsigned long errorSize) {
    pthread_mutex_lock(&StartLock);
    if (atomic_load_explicit(&EngineReady,memory_order_acquire)) {
        pthread_mutex_unlock(&StartLock);return true;
    }
    bool ready=false;
    if (!image) { snprintf(error,errorSize,"Steam client image missing");goto finish; }
    if (Prepared.image && Prepared.image!=image) {
        snprintf(error,errorSize,"a different Steam client requires restarting AgePad");goto finish;
    }
    void *(*create)(const char *,int *)=(void *(*)(const char *,int *))dlsym(image,"CreateInterface");
    if (!Prepared.engine) {
        int status=0;
        void *engine=create?create("CLIENTENGINE_INTERFACE_VERSION005",&status):NULL;
        if (!engine || !strstr(TypeName(engine),"CSteamClient")) {
            snprintf(error,errorSize,"engine interface unavailable");goto finish;
        }
        if (!Slot(engine,2) || !Slot(engine,8) || !Slot(engine,19)) {
            snprintf(error,errorSize,"engine methods unavailable");goto finish;
        }
        Prepared.image=image;Prepared.engine=engine;
    }
    if (!Prepared.globalUser || !Prepared.pipe) {
        HSteamPipe pipe=0;
        HSteamUser user=((HSteamUser (*)(void *,HSteamPipe *))Slot(Prepared.engine,2))(Prepared.engine,&pipe);
        if (!user || !pipe) { snprintf(error,errorSize,"CreateGlobalUser failed");goto finish; }
        Prepared.pipe=pipe;Prepared.globalUser=user;
    }
    void *user=((void *(*)(void *,HSteamUser,HSteamPipe))Slot(Prepared.engine,8))
        (Prepared.engine,Prepared.globalUser,Prepared.pipe);
    if (!user || strcmp(TypeName(user),"14IClientUserMap")) {
        snprintf(error,errorSize,"IClientUser not at the expected slot (%s)",user?TypeName(user):"null");goto finish;
    }
    EngineMethods methods={0};
    struct { const char *name;int *slot; } wanted[]={
        {"LogOn",&methods.logOn},{"LogOff",&methods.logOff},{"BLoggedOn",&methods.loggedOn},
        {"GetLogonState",&methods.logonState},{"BConnected",&methods.connected},{"GetSteamID",&methods.steamID},
        {"SetLoginToken",&methods.setLoginToken},{"LogOnOffline",&methods.logOnOffline},{"BIsSubscribedApp",&methods.subscribed},
        {"CanLogonOffline",&methods.canOffline}};
    for (unsigned i=0;i<sizeof(wanted)/sizeof(*wanted);i++) {
        *wanted[i].slot=FindMethod(user,wanted[i].name,(void *)create);
        if (*wanted[i].slot<0) { snprintf(error,errorSize,"IClientUser::%s not found",wanted[i].name);goto finish; }
    }
    pthread_t thread;
    int threadError=pthread_create(&thread,NULL,Pump,Prepared.engine);
    if (threadError) { snprintf(error,errorSize,"Steam frame pump could not start (%d)",threadError);goto finish; }
    pthread_detach(thread);
    Prepared.user=user;Prepared.methods=methods;
    ActiveEngine=Prepared;
    atomic_store_explicit(&EngineReady,true,memory_order_release);
    if (error && errorSize) error[0]=0;
    ready=true;
finish:
    pthread_mutex_unlock(&StartLock);return ready;
}
static bool Ready(void) { return atomic_load_explicit(&EngineReady,memory_order_acquire); }
void AgePadEngineSetLoginToken(const char *token,const char *account) {
    if (Ready()) ((void (*)(void *,const char *,const char *))Slot(ActiveEngine.user,ActiveEngine.methods.setLoginToken))(ActiveEngine.user,token,account);
}
int AgePadEngineLogOn(uint64_t steamID) { return Ready()?((int (*)(void *,uint64_t))Slot(ActiveEngine.user,ActiveEngine.methods.logOn))(ActiveEngine.user,steamID):-1; }
int AgePadEngineLogOnOffline(void) { return Ready()?((int (*)(void *,bool))Slot(ActiveEngine.user,ActiveEngine.methods.logOnOffline))(ActiveEngine.user,true):-1; }
void AgePadEngineLogOff(void) { if (Ready()) ((void (*)(void *))Slot(ActiveEngine.user,ActiveEngine.methods.logOff))(ActiveEngine.user); }
bool AgePadEngineLoggedOn(void) { return Ready() && ((bool (*)(void *))Slot(ActiveEngine.user,ActiveEngine.methods.loggedOn))(ActiveEngine.user); }
bool AgePadEngineConnected(void) { return Ready() && ((bool (*)(void *))Slot(ActiveEngine.user,ActiveEngine.methods.connected))(ActiveEngine.user); }
int AgePadEngineLogonState(void) { return Ready()?((int (*)(void *))Slot(ActiveEngine.user,ActiveEngine.methods.logonState))(ActiveEngine.user):-1; }
uint64_t AgePadEngineSteamID(void) { return Ready()?((uint64_t (*)(void *))Slot(ActiveEngine.user,ActiveEngine.methods.steamID))(ActiveEngine.user):0; }
bool AgePadEngineOwnsApp(uint32_t appID) { return Ready() && ((bool (*)(void *,uint32_t))Slot(ActiveEngine.user,ActiveEngine.methods.subscribed))(ActiveEngine.user,appID); }
int AgePadEngineCanLogOnOffline(void) { return Ready()?((int (*)(void *))Slot(ActiveEngine.user,ActiveEngine.methods.canOffline))(ActiveEngine.user):-1; }
kern_return_t AgePadEngineRegister(const char *clientPath,kern_return_t (*lookUp)(mach_port_t,const char *,mach_port_t *)) {
    mach_port_t service=MACH_PORT_NULL;
    kern_return_t status=lookUp(bootstrap_port,"com.valvesoftware.steam.ipctool",&service);
    if (status!=KERN_SUCCESS) return status;
    struct { mach_msg_header_t header; uint32_t operation,pid; char path[512]; } request;
    memset(&request,0,sizeof(request));
    request.header.msgh_bits=MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND,0);
    request.header.msgh_size=sizeof(request);request.header.msgh_remote_port=service;request.header.msgh_id=104;
    request.operation=13;request.pid=(uint32_t)getpid();strlcpy(request.path,clientPath,sizeof(request.path));
    status=mach_msg(&request.header,MACH_SEND_MSG|MACH_SEND_TIMEOUT,sizeof(request),0,MACH_PORT_NULL,2000,MACH_PORT_NULL);
    mach_port_deallocate(mach_task_self(),service);
    return status;
}
