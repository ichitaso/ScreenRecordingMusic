#import <Foundation/Foundation.h>

#define Notify_Preferences "com.ichitaso.srmusic.preferencechanged"

static BOOL isRecording;

@interface AVPlayer : NSObject
- (void)setMuted:(BOOL)arg1;
- (BOOL)isMuted;
@end

%group Recorder
// Check Recording
%hook RPScreenRecorder
- (void)setRecording:(BOOL)arg1 {
    %orig;
    [[NSNotificationCenter defaultCenter] postNotificationName:@Notify_Preferences object:nil];
}
%end
// Enable Lockscreen Recording
%hook RPRecordingManager
- (void)setUpDeviceLockNotifications {}
- (void)setDeviceLocked:(BOOL)arg1 {
    %orig(NO);
}
- (BOOL)deviceLocked {
    return NO;
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
    if (isRecording) {
        %orig(NO);
    } else {
        %orig;
    }
}
%end
%end

%group SpringBoard
// allows button to be pressed on lockscreen
%hook RPControlCenterModuleViewController
- (void)moduleAuthenticateWithCompletionHandler:(void(^)(BOOL))arg1
{
    arg1(YES);
}
%end
%end

%ctor {
    @autoreleasepool {
        if ([[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
            // load ReplayKitModule bundle
            NSBundle *moduleBundle = [NSBundle bundleWithPath:@"/System/Library/ControlCenter/Bundles/ReplayKitModule.bundle"];
            if (!moduleBundle.loaded) {
                [moduleBundle load];
            }
            %init(SpringBoard);
        } else {
            %init(Recorder);
        }
    }
}
