/*
 * ScreenRecordingMusic
 * Copyright (C) 2022-2026 ichitaso
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published
 * by the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <notify.h>
#import <objc/message.h>
#import <dlfcn.h>
#if __has_feature(ptrauth_calls)
#import <ptrauth.h>
#endif

#define Notify_Preferences "com.ichitaso.srmusic.preferencechanged"
#define Notify_RecordingState "com.ichitaso.srmusic.recordingstate"

#ifdef DEBUG
#undef NSLog
    #define NSLog(fmt, ...) CustomOSLogBridge(fmt, ##__VA_ARGS__)
static inline void CustomOSLogBridge(NSString *format, ...) {
    if (!format) return;
    NSString *extendedFormat = [@"[ScreenRecordingMusic] " stringByAppendingString:format];
    NSString *safeFormat = [extendedFormat stringByReplacingOccurrencesOfString:@"%{public}" withString:@"%"];
    safeFormat = [safeFormat stringByReplacingOccurrencesOfString:@"%{private}" withString:@"%"];
    va_list args;
    va_start(args, format);
    NSString *formattedMessage = [[NSString alloc] initWithFormat:safeFormat arguments:args];
    va_end(args);
    if (formattedMessage) {
        os_log(OS_LOG_DEFAULT, "%{public}s", [formattedMessage UTF8String]);
    }
}
#else
    #define NSLog(fmt, ...)
#endif

static BOOL isRecording;

@interface AVPlayer : NSObject
- (void)setMuted:(BOOL)arg1;
- (BOOL)isMuted;
@end

// iOS 14: MediaFoundation mutes Music's AVPlayer by itself when screen recording starts
// (it only mutes the player for that policy, and UIScreen isCaptured is not updated yet at that point)
static BOOL isMediaFoundationCaller(void *caller) {
#if __has_feature(ptrauth_calls)
    caller = ptrauth_strip(caller, ptrauth_key_return_address);
#endif
    Dl_info info;
    return dladdr(caller, &info) && info.dli_fname && strstr(info.dli_fname, "/MediaFoundation.framework/");
}

@interface RPClientManager : NSObject
+ (instancetype)sharedInstance;
- (id)getClientWithBundleID:(NSString *)bundleID;
@end

@interface NSObject (ScreenRecordingMusic)
- (id)clientProxy;
- (int)clientPID;
- (void)updateClientProxy:(id)proxy callingPID:(int)pid bundleID:(NSString *)bundleID;
- (void)setUpStatusBarAssertionWithServiceName:(NSString *)serviceName;
- (int)sessionState;
@end

@interface RPScreenRecorder : NSObject
+ (instancetype)sharedRecorder;
- (BOOL)isRecording;
- (void)setRecording:(BOOL)recording;
- (void)notifyDelegateOfUpdatedState;
@end

@interface RPControlCenterClient : NSObject
+ (instancetype)sharedInstance;
- (BOOL)recordingOn;
- (unsigned long long)recordingType;
- (void)setRecordingType:(unsigned long long)type;
- (void)screenRecorderDidUpdateState:(RPScreenRecorder *)recorder;
- (void)updateStatusIsCountingDown:(BOOL)countingDown IsRecording:(BOOL)recording;
- (void)callDelegate:(void(^)(id delegate))block;
@end

// replayd publishes whether a system recording is running, SpringBoard follows it after respring
static void publishRecordingState(BOOL active) {
    static int token = NOTIFY_TOKEN_INVALID;
    if (token == NOTIFY_TOKEN_INVALID) notify_register_check(Notify_RecordingState, &token);
    notify_set_state(token, active);
    notify_post(Notify_RecordingState);
}

static void syncRecordingState() {
    int token;
    uint64_t state = 0;
    if (notify_register_check(Notify_RecordingState, &token) != NOTIFY_STATUS_OK) return;
    notify_get_state(token, &state);
    notify_cancel(token);

    RPScreenRecorder *recorder = [objc_getClass("RPScreenRecorder") sharedRecorder];
    BOOL active = state != 0;
    if (!recorder) return;
    // the Control Center module reads isRecording on this callback
    if ([recorder isRecording] != active) [recorder setRecording:active];
    if ([recorder respondsToSelector:@selector(notifyDelegateOfUpdatedState)]) {
        [recorder notifyDelegateOfUpdatedState];
    }
    // iOS 18 and later: the Control Center client is shared and may not be the recorder's delegate yet
    Class clientClass = objc_getClass("RPControlCenterClient");
    if ([clientClass respondsToSelector:@selector(sharedInstance)]) {
        RPControlCenterClient *client = [clientClass sharedInstance];
        BOOL wasOn = [client recordingOn];
        // iOS 26: the client has its own recorder instead of the shared one
        Ivar recorderIvar = class_getInstanceVariable(object_getClass(client), "_screenRecorder");
        RPScreenRecorder *clientRecorder = recorderIvar ? object_getIvar(client, recorderIvar) : nil;
        if (clientRecorder && [clientRecorder isRecording] != active) [clientRecorder setRecording:active];
        // iOS 26 ignores the state unless the client's recording type is system recording (1 or 2), 0 is none
        if (active && [client respondsToSelector:@selector(setRecordingType:)] && [client recordingType] == 0) {
            [client setRecordingType:1];
        }
        [client screenRecorderDidUpdateState:clientRecorder ?: recorder];
        // iOS 26 only updates its ivars on the callback, so tell the module views as the start/stop handlers do
        if (wasOn != active) {
            [client updateStatusIsCountingDown:NO IsRecording:active];
            [client callDelegate:^(id delegate) {
                SEL sel = active ? @selector(didStartRecordingOrBroadcast) : @selector(didStopRecordingOrBroadcast);
                if ([delegate respondsToSelector:sel]) ((void (*)(id, SEL))objc_msgSend)(delegate, sel);
            }];
        }
    }
    NSLog(@"synced recording state:%d", active);
}

// RPClientProxy of a disconnected client, retained so the kept session never messages a freed proxy
static NSMutableDictionary *keptProxies;

// RPClient (its name collides with Rapport.framework) keeps its sessions even after they stop,
// so look for a system recording/broadcast session that is running (session state 1: recording, 4: paused)
static id activeSystemSession(id client) {
    if (!client) return nil;
    Ivar typeIvar = class_getInstanceVariable(object_getClass(client), "_currentActiveSession");
    if (!typeIvar || *(int *)((uint8_t *)(__bridge void *)client + ivar_getOffset(typeIvar)) == 0) return nil;
    for (NSString *name in @[@"_systemRecordSession", @"_systemBroadcastSession"]) {
        Ivar sessionIvar = class_getInstanceVariable(object_getClass(client), name.UTF8String);
        id session = sessionIvar ? object_getIvar(client, sessionIvar) : nil;
        if (![session respondsToSelector:@selector(sessionState)]) continue;
        int state = ((int (*)(id, SEL))objc_msgSend)(session, @selector(sessionState));
        if (state == 1 || state == 4) return session;
    }
    return nil;
}

%group Recorder
// Check Recording
%hook RPScreenRecorder
- (void)setRecording:(BOOL)arg1 {
    %orig;
    [[NSNotificationCenter defaultCenter] postNotificationName:@Notify_Preferences object:nil];
    NSLog(@"setRecording:");
}
%end
// Enable Lockscreen Recording (iOS 16 and earlier)
%hook RPRecordingManager
- (void)setUpDeviceLockNotifications {}
- (void)setDeviceLocked:(BOOL)arg1 {
    %orig(NO);
}
- (BOOL)deviceLocked {
    return NO;
}
// Keep system recording when its client (SpringBoard) disconnects, e.g. respring
- (void)applicationDisconnectedWithBundleID:(NSString *)bundleID withProcessIdentifier:(int)pid {
    id client = [[objc_getClass("RPClientManager") sharedInstance] getClientWithBundleID:bundleID];
    if (activeSystemSession(client)) {
        // the new SpringBoard may already be connected (and reattached) before the old connection is invalidated
        if ([client clientPID] == pid) {
            @synchronized (keptProxies) {
                id proxy = [client clientProxy];
                if (proxy) keptProxies[bundleID] = proxy;
            }
            // SpringBoard may not reconnect until Control Center is used, so register the status bar with the new one
            // (not on the main queue, setUpStatusBarAssertionWithServiceName: syncs to it)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                @synchronized (keptProxies) {
                    if (!keptProxies[bundleID]) return;
                }
                id session = activeSystemSession(client);
                [session setUpStatusBarAssertionWithServiceName:nil];
                NSLog(@"registered status bar for kept session:%@", session);
            });
        }
        NSLog(@"keep system session for disconnected client:%@", bundleID);
        return;
    }
    %orig;
}
// Reattach the kept session to the reconnected client
- (void)connectionManagerDidAcceptNewConnection:(id)connection bundleIdentifier:(NSString *)bundleID {
    id client = [[objc_getClass("RPClientManager") sharedInstance] getClientWithBundleID:bundleID];
    // hold the current proxy while %orig replaces it, the session still refers to it
    id oldProxy = [client clientProxy];
    %orig;

    id session = activeSystemSession(client);
    if (session && [client clientProxy] != oldProxy) {
        [session updateClientProxy:[client clientProxy] callingPID:[client clientPID] bundleID:bundleID];
        [session setUpStatusBarAssertionWithServiceName:nil];
        NSLog(@"reattached system session to client:%@ pid:%d", bundleID, [client clientPID]);
    }
    @synchronized (keptProxies) {
        [keptProxies removeObjectForKey:bundleID];
    }
}
%end
// Check Recording
%hook AVPlayer
- (id)init {
    id orig = %orig;

    [[NSNotificationCenter defaultCenter] addObserver:orig
                                             selector:@selector(recievedUpdate)
                                                 name:@Notify_Preferences
                                               object:nil];

    NSLog(@"AVPlayer init");

    return orig;
}
%new
- (void)recievedUpdate {
    isRecording = YES;
    [self isMuted];
    [self setMuted:NO];
}
// Enable Music Recording
- (BOOL)isMuted {
    if (isRecording) {
        return NO;
    }
    return %orig;
}
- (void)setMuted:(BOOL)arg1 {
    if (isRecording || (arg1 && isMediaFoundationCaller(__builtin_return_address(0)))) {
        %orig(NO);
    } else {
        %orig;
    }
}
%end
%end

// Enable Lockscreen Recording (iOS 17 and later)
%group Session
%hook RPSession
- (void)setUpDeviceLockNotifications {}
- (void)setDeviceLocked:(BOOL)arg1 {
    %orig(NO);
}
- (BOOL)deviceLocked {
    return NO;
}
- (id)checkDeviceLockedRequirement {
    return nil;
}
// 1: recording, 4: paused (stop alert is shown)
- (void)setSessionState:(int)state {
    %orig;
    if ([self isKindOfClass:objc_getClass("RPSystemRecordSession")] || [self isKindOfClass:objc_getClass("RPSystemBroadcastSession")]) {
        publishRecordingState(state == 1 || state == 4);
    }
}
%end
%end

// Enable Music Recording
// Music mutes the player while the screen is recorded, so tell it that recording is allowed or not running
%group Playback
// iOS 12 - 14
%hook MPAVPolicyEnforcer
- (void)_isScreenRecordingDidChange:(BOOL)arg1 {
    %orig(NO);
}
%end
// iOS 14 - 16
%hook _MPCPlaybackEngineMediaFoundationImplementation
- (void)screenRecordingDidChange:(BOOL)arg1 timeStamp:(id)arg2 {
    %orig(NO, arg2);
}
%end
// iOS 16
%hook MPCPlaybackDefaultsImplementation
- (BOOL)allowScreenRecording {
    return YES;
}
%end
// iOS 16 and later
%hook MPPlaybackUserDefaults
- (BOOL)allowScreenRecording {
    return YES;
}
%end
%hook MFPodcastsPlaybackDefaults
- (BOOL)allowScreenRecording {
    return YES;
}
%end
%end

%group SpringBoard
// allows button to be pressed on lockscreen (iOS 16 and earlier)
%hook RPControlCenterModuleViewController
- (void)moduleAuthenticateWithCompletionHandler:(void(^)(BOOL))arg1 {
    NSLog(@"isRecording:%d",isRecording);
    arg1(YES);
}
%end
// allows button to be pressed on lockscreen (iOS 17 and later)
%hook RPControlCenterMenuModuleViewController
- (void)authenticateWithCompletionHandler:(void(^)(BOOL))arg1 {
    arg1(YES);
}
%end
%end

// RPSession subclasses override handleDeviceLockedWarning, which stops recording on lock or screen off
static void handleDeviceLockedWarning(id self, SEL _cmd) {}

static void hookDeviceLockedWarning(Class sessionClass) {
    SEL sel = @selector(handleDeviceLockedWarning);
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    for (unsigned int i = 0; i < count; i++) {
        for (Class cls = classes[i]; cls; cls = class_getSuperclass(cls)) {
            if (cls != sessionClass) continue;
            // only hook classes that implement the method themselves
            unsigned int methodCount = 0;
            Method *methods = class_copyMethodList(classes[i], &methodCount);
            for (unsigned int j = 0; j < methodCount; j++) {
                if (method_getName(methods[j]) == sel) {
                    MSHookMessageEx(classes[i], sel, (IMP)handleDeviceLockedWarning, NULL);
                    NSLog(@"hooked -[%s handleDeviceLockedWarning]", class_getName(classes[i]));
                    break;
                }
            }
            free(methods);
            break;
        }
    }
    free(classes);
}

%ctor {
    @autoreleasepool {
        if ([[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
            // load ReplayKitModule bundle
            NSBundle *moduleBundle = [NSBundle bundleWithPath:@"/System/Library/ControlCenter/Bundles/ReplayKitModule.bundle"];
            if (!moduleBundle.loaded) {
                [moduleBundle load];
            }
            %init(SpringBoard);
            int token;
            notify_register_dispatch(Notify_RecordingState, &token, dispatch_get_main_queue(), ^(int t) {
                syncRecordingState();
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                syncRecordingState();
            });
        } else {
            keptProxies = [NSMutableDictionary dictionary];
            %init(Recorder);
            %init(Playback);
            // Rapport.framework also has a class named RPSession, so get the replayd one from its subclass
            Class sessionClass = class_getSuperclass(objc_getClass("RPRecordSession"));
            if (sessionClass) {
                %init(Session, RPSession = sessionClass);
                publishRecordingState(NO);
                hookDeviceLockedWarning(sessionClass);
            }
        }
    }
}
