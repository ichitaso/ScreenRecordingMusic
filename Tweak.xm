#import <Foundation/Foundation.h>

%group Recorder
%hook RPRecordingManager
// Enable Lockscreen Recording
- (void)setUpDeviceLockNotifications {}
- (void)setDeviceLocked:(BOOL)arg1 {
    %orig(NO);
}
-(BOOL)deviceLocked {
    return NO;
}
%end
// Enable Music Recording
%hook AVPlayer
- (BOOL)isMuted {
    return NO;
}
- (void)setMuted:(BOOL)arg1 {
    %orig(NO);
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
