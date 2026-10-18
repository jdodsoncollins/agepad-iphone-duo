// Production startup, with a synthetic Valve interface. No Steam image, network,
// account, frame thread, or device is involved. Never execute the fake ARM64 code.
#include <assert.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>

static void *FixtureDlsym(void *,const char *);
static int FixtureDladdr(const void *,Dl_info *);
static int FixtureThreadCreate(pthread_t *,const pthread_attr_t *,void *(*)(void *),void *);
static int FixtureThreadDetach(pthread_t);
#define dlsym FixtureDlsym
#define dladdr FixtureDladdr
#define pthread_create FixtureThreadCreate
#define pthread_detach FixtureThreadDetach
#include "../port/steam-engine/SteamEngineHost.c"
#undef dlsym
#undef dladdr
#undef pthread_create
#undef pthread_detach

static unsigned checks,creates,globalCreates,userQueries,threads;
static int threadError;
static bool engineAvailable,globalAvailable,owns;
static void *engineType[2],*userType[2];
static void *engineVtable[22],*userVtable[402];
static void **engineObject,*userObject;
static struct { uint32_t code[4];char name[64]; } proxy[10];
static const char *names[]={"LogOn","LogOff","BLoggedOn","GetLogonState","BConnected","GetSteamID","SetLoginToken","LogOnOffline","BIsSubscribedApp","CanLogonOffline"};
static void check(bool value) { assert(value);checks++; }
static HSteamUser CreateGlobal(void *engine,HSteamPipe *pipe) {
    assert(engine==&engineObject);globalCreates++;
    if (!globalAvailable) { *pipe=0;return 0; }*pipe=13;return 17;
}
static void *GetUser(void *engine,HSteamUser user,HSteamPipe pipe) {
    assert(engine==&engineObject && user==17 && pipe==13);userQueries++;return &userObject;
}
static void RunFrame(void *engine) { (void)engine;assert(!"Fixture must not run a frame thread"); }
static void *CreateInterface(const char *name,int *status) {
    assert(!strcmp(name,"CLIENTENGINE_INTERFACE_VERSION005"));creates++;*status=0;
    return engineAvailable?&engineObject:NULL;
}
static void *FixtureDlsym(void *image,const char *name) {
    assert(image==(void *)0x1234);return !strcmp(name,"CreateInterface")?(void *)CreateInterface:NULL;
}
static int FixtureDladdr(const void *function,Dl_info *info) {
    if (!function) return 0;memset(info,0,sizeof *info);info->dli_fbase=(void *)1;return 1;
}
static int FixtureThreadCreate(pthread_t *thread,const pthread_attr_t *attributes,void *(*entry)(void *),void *argument) {
    assert(!attributes && entry==Pump && argument==&engineObject);threads++;
    if (threadError) return threadError;*thread=(pthread_t)(uintptr_t)1;return 0;
}
static int FixtureThreadDetach(pthread_t thread) { assert(thread==(pthread_t)(uintptr_t)1);return 0; }
static bool OwnsApp(void *user,uint32_t app) { assert(user==&userObject && app==813780);return owns; }
static void reset(void) {
    memset(&Prepared,0,sizeof Prepared);memset(&ActiveEngine,0,sizeof ActiveEngine);atomic_store(&EngineReady,false);
    creates=globalCreates=userQueries=threads=0;threadError=0;engineAvailable=globalAvailable=true;owns=false;
    memset(engineVtable,0,sizeof engineVtable);memset(userVtable,0,sizeof userVtable);
    engineType[1]=(void *)"CSteamClientFixture";userType[1]=(void *)"14IClientUserMap";
    engineVtable[0]=engineType;userVtable[0]=userType;
    engineObject=engineVtable+1;userObject=userVtable+1;
    engineObject[2]=(void *)CreateGlobal;engineObject[8]=(void *)GetUser;engineObject[19]=(void *)RunFrame;
    for (unsigned i=0;i<10;i++) {
        strcpy(proxy[i].name,names[i]);
        uintptr_t source=(uintptr_t)&proxy[i].code[0],target=(uintptr_t)proxy[i].name;
        int64_t pages=((int64_t)(target&~(uintptr_t)4095)-(int64_t)(source&~(uintptr_t)4095))/4096;
        uint32_t immediate=(uint32_t)pages&0x1fffff;
        proxy[i].code[0]=0x90000004|((immediate&3)<<29)|((immediate>>2)<<5);
        proxy[i].code[1]=0x91000084|((uint32_t)(target&4095)<<10);proxy[i].code[2]=0xd65f03c0;
        ((void **)userObject)[i]=proxy[i].code;
    }
}
static void notReady(void) {
    check(!Ready() && !ActiveEngine.user && !AgePadEngineLoggedOn() && !AgePadEngineConnected());
    check(AgePadEngineLogOn(76561198000000001ULL)==-1 && AgePadEngineLogOnOffline()==-1);
    check(!AgePadEngineOwnsApp(813780) && AgePadEngineSteamID()==0 && AgePadEngineLogonState()==-1 && AgePadEngineCanLogOnOffline()==-1);
    AgePadEngineSetLoginToken("fixture","fixture");AgePadEngineLogOff();
}
int main(void) {
    char error[160];
    reset();check(!AgePadEngineStart(NULL,error,sizeof error));notReady();check(creates==0 && threads==0);
    reset();engineAvailable=false;check(!AgePadEngineStart((void *)0x1234,error,sizeof error));notReady();check(threads==0);
    reset();globalAvailable=false;check(!AgePadEngineStart((void *)0x1234,error,sizeof error));notReady();
    globalAvailable=true;check(AgePadEngineStart((void *)0x1234,error,sizeof error));check(Ready() && threads==1);
    reset();userType[1]=(void *)"wrong-user-type";
    check(!AgePadEngineStart((void *)0x1234,error,sizeof error));notReady();
    check(!AgePadEngineStart((void *)0x1234,error,sizeof error));notReady();check(globalCreates==1);
    userType[1]=(void *)"14IClientUserMap";
    check(AgePadEngineStart((void *)0x1234,error,sizeof error));check(globalCreates==1 && threads==1);
    reset();strcpy(proxy[8].name,"missing-subscription-method");
    check(!AgePadEngineStart((void *)0x1234,error,sizeof error) && strstr(error,"BIsSubscribedApp"));notReady();
    // This is the original bug: partial User state made the second call return
    // true despite a missing method and no frame pump.
    check(!AgePadEngineStart((void *)0x1234,error,sizeof error));notReady();check(threads==0 && globalCreates==1);
    strcpy(proxy[8].name,names[8]);
    check(AgePadEngineStart((void *)0x1234,error,sizeof error));check(Ready() && !error[0] && threads==1 && globalCreates==1);
    check(ActiveEngine.methods.subscribed==8 && ActiveEngine.methods.setLoginToken==6);
    ((void **)userObject)[8]=(void *)OwnsApp;
    check(!AgePadEngineOwnsApp(813780));owns=true;check(AgePadEngineOwnsApp(813780));
    check(AgePadEngineStart((void *)0x1234,error,sizeof error) && threads==1 && globalCreates==1);
    reset();threadError=EAGAIN;
    check(!AgePadEngineStart((void *)0x1234,error,sizeof error) && strstr(error,"frame pump"));notReady();
    check(threads==1 && globalCreates==1);
    threadError=0;check(AgePadEngineStart((void *)0x1234,error,sizeof error));
    check(threads==2 && globalCreates==1 && Ready());
    puts("Steam engine startup: failure/retry and genuine ownership forwarding passed");
    printf("%u focused checks; no Steam, network, account, device, or frame thread\n",checks);
    return 0;
}
