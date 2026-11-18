#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"
#import "../../UI/OverlayButtonHost.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>

static NSString *const YTKACEAutoFullscreenKey = @"YTKACE.Preference.Player.AutoFullscreen";
static NSString *const YTKACEExitFullscreenKey = @"YTKACE.Preference.Player.ExitFullscreenAtEnd";
static NSString *const YTKACEFlipLandscapeKey = @"YTKACE.Preference.Player.FlipLandscape";

static NSString *YTKACEFullscreenEnteredVideo;
static NSString *YTKACEFullscreenExitedVideo;

static id YTKACEFullscreenGet(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (object == nil || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static double YTKACEFullscreenDouble(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (object == nil || ![object respondsToSelector:selector]) return 0.0;
    return ((double (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSString *YTKACEFullscreenVideoID(id player) {
    id value = YTKACEFullscreenGet(player, @"currentVideoID");
    return [value isKindOfClass:NSString.class] ? value : nil;
}

// Only the watch page player, not feed previews or Shorts.
static id YTKACEMainOverlay(id player) {
    id overlay = YTKACEFullscreenGet(player, @"activeVideoPlayerOverlay");
    Class main = NSClassFromString(@"YTMainAppVideoPlayerOverlayViewController");
    return main != Nil && [overlay isKindOfClass:main] ? overlay : nil;
}

static BOOL YTKACEPlayerIsFullscreen(id overlay) {
    SEL selector = NSSelectorFromString(@"isFullscreen");
    return [overlay respondsToSelector:selector] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(overlay, selector);
}

// The miniplayer and a backgrounded app shouldn't jump into fullscreen.
static BOOL YTKACEPlayerOnScreen(id player) {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return NO;
    UIView *view = [player isKindOfClass:UIViewController.class] ? ((UIViewController *)player).view : nil;
    UIWindow *window = view.window;
    if (window == nil || view.hidden || CGRectIsEmpty(window.bounds)) return NO;
    CGRect frame = [view convertRect:view.bounds toView:window];
    return CGRectGetWidth(frame) >= CGRectGetWidth(window.bounds) * 0.5;
}

// The overlay has the toggle on new versions, the player on older ones.
static void YTKACEToggleFullscreen(id player, NSString *stage) {
    SEL toggle = NSSelectorFromString(@"didPressToggleFullscreen");
    id overlay = YTKACEMainOverlay(player);
    id target = [overlay respondsToSelector:toggle] ? overlay
        : [player respondsToSelector:toggle] ? player : nil;
    if (target == nil) {
        YTKACEDebugLog(@"fullscreen", @"%@ toggle unavailable", stage);
        return;
    }
    ((void (*)(id, SEL))objc_msgSend)(target, toggle);
    YTKACEDebugLog(@"fullscreen", @"%@ toggled on %@", stage, NSStringFromClass([target class]));
}

void YTKACEFullscreenVideoActivated(id player) {
    if (!YTKACEFeatureEnabled(YTKACEAutoFullscreenKey) || YTKACEMainOverlay(player) == nil) return;
    NSString *videoID = YTKACEFullscreenVideoID(player);
    if (videoID.length == 0 || [videoID isEqualToString:YTKACEFullscreenEnteredVideo]) return;
    YTKACEFullscreenEnteredVideo = [videoID copy];
    __weak id weakPlayer = player;
    // wait for the watch page to finish opening
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        id strong = weakPlayer;
        id overlay = YTKACEMainOverlay(strong);
        if (overlay == nil || ![YTKACEFullscreenVideoID(strong) isEqualToString:videoID]) return;
        if (YTKACEPlayerIsFullscreen(overlay)) return;
        if (!YTKACEPlayerOnScreen(strong)) {
            YTKACEDebugLog(@"fullscreen", @"auto skipped video=%@ not on screen", videoID);
            return;
        }
        YTKACEToggleFullscreen(strong, @"auto");
    });
}

static BOOL YTKACELoopOn(void) {
    return YTKACEFeatureEnabled(YTKACELoopKey) &&
        [NSUserDefaults.standardUserDefaults boolForKey:@"defaultLoop_enabled"];
}

@interface YTKACEFullscreenObserver : NSObject
@end

@implementation YTKACEFullscreenObserver

- (void)timeChanged:(NSNotification *)notification {
    if (!YTKACEFeatureEnabled(YTKACEExitFullscreenKey)) return;
    id player = notification.object;
    id overlay = YTKACEMainOverlay(player);
    if (overlay == nil) return;
    const double time = [notification.userInfo[@"time"] doubleValue];
    const double total = YTKACEFullscreenDouble(player, @"currentVideoTotalMediaTime");
    if (total <= 1.0 || time < total - 0.35) return;
    NSString *videoID = YTKACEFullscreenVideoID(player);
    if (videoID.length == 0 || [videoID isEqualToString:YTKACEFullscreenExitedVideo]) return;
    YTKACEFullscreenExitedVideo = [videoID copy];
    if (!YTKACEPlayerIsFullscreen(overlay) || YTKACELoopOn() || YTKACEQueueVideoIsLive(videoID, player)) return;
    YTKACEToggleFullscreen(player, @"end");
}

@end


// Flip landscape: with rotation lock on, fullscreen sometimes lands on the
// wrong landscape side. This button turns the video to the other side.

static UIInterfaceOrientation YTKACESceneOrientation(UIView *view) {
    UIWindowScene *scene = view.window.windowScene;
    return scene != nil ? scene.interfaceOrientation : UIInterfaceOrientationUnknown;
}

// The controls overlay's view controller says whether it is fullscreen;
// without one, a landscape window is taken as fullscreen.
static BOOL YTKACEOverlayViewIsFullscreen(UIView *view) {
    Class main = NSClassFromString(@"YTMainAppVideoPlayerOverlayViewController");
    UIResponder *responder = view;
    while (responder != nil) {
        if (main != Nil && [responder isKindOfClass:main]) return YTKACEPlayerIsFullscreen(responder);
        responder = responder.nextResponder;
    }
    return YES;
}

static BOOL YTKACEFlipButtonWanted(UIView *overlay) {
    if (!YTKACEFeatureEnabled(YTKACEFlipLandscapeKey)) return NO;
    if (!UIInterfaceOrientationIsLandscape(YTKACESceneOrientation(overlay))) return NO;
    return YTKACEOverlayViewIsFullscreen(overlay);
}

static void YTKACEUpdateSupportedOrientations(UIViewController *controller) {
    if (@available(iOS 16.0, *)) {
        while (controller != nil) {
            [controller setNeedsUpdateOfSupportedInterfaceOrientations];
            controller = controller.presentedViewController;
        }
    }
}

@interface YTKACEFlipLandscapeTarget : NSObject
@property(nonatomic, weak) UIView *overlay;
+ (instancetype)sharedTarget;
- (void)flip;
@end

@implementation YTKACEFlipLandscapeTarget

+ (instancetype)sharedTarget {
    static YTKACEFlipLandscapeTarget *target;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ target = [YTKACEFlipLandscapeTarget new]; });
    return target;
}

- (void)flip {
    UIView *overlay = self.overlay;
    UIWindow *window = overlay.window;
    const UIInterfaceOrientation current = YTKACESceneOrientation(overlay);
    if (window == nil || !UIInterfaceOrientationIsLandscape(current)) return;
    const UIInterfaceOrientation target = current == UIInterfaceOrientationLandscapeLeft
        ? UIInterfaceOrientationLandscapeRight : UIInterfaceOrientationLandscapeLeft;
    YTKACEDebugLog(@"fullscreen", @"flip landscape %ld -> %ld", (long)current, (long)target);
    if (@available(iOS 16.0, *)) {
        const UIInterfaceOrientationMask mask = target == UIInterfaceOrientationLandscapeLeft
            ? UIInterfaceOrientationMaskLandscapeLeft : UIInterfaceOrientationMaskLandscapeRight;
        YTKACEUpdateSupportedOrientations(window.rootViewController);
        UIWindowSceneGeometryPreferencesIOS *preferences =
            [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:mask];
        [window.windowScene requestGeometryUpdateWithPreferences:preferences
                                                    errorHandler:^(NSError *error) {
            YTKACEDebugLog(@"fullscreen", @"flip landscape failed %@", error.localizedDescription);
        }];
    } else {
        // UIDeviceOrientationLandscapeLeft/Right are the interface values swapped,
        // which is the same number as the interface orientation we want.
        [UIDevice.currentDevice setValue:@(target) forKey:@"orientation"];
        [UIViewController attemptRotationToDeviceOrientation];
    }
}

@end

static void YTKACERegisterFlipLandscapeButton(void) {
    YTKACERegisterOverlayConfigurator(@"fliplandscape", ^(UIView *overlay, UIStackView *stack) {
        YTKACEFlipLandscapeTarget *target = YTKACEFlipLandscapeTarget.sharedTarget;
        UIImage *probe = nil;
        if (@available(iOS 16.0, *)) probe = [UIImage systemImageNamed:@"rectangle.landscape.rotate"];
        UIButton *button = YTKACEOverlayButton(stack, @"YTKACE Flip Landscape",
                                               probe != nil ? @"rectangle.landscape.rotate" : @"arrow.triangle.2.circlepath",
                                               target, @selector(flip));
        button.accessibilityLabel = @"Flip Landscape";
        const BOOL wanted = YTKACEFlipButtonWanted(overlay);
        if (wanted) target.overlay = overlay;
        button.hidden = !wanted;
    });
}

void YTKACEInstallFullscreenHooks(void) {
    YTKACERegisterFlipLandscapeButton();
    static YTKACEFullscreenObserver *observer;
    observer = [YTKACEFullscreenObserver new];
    [NSNotificationCenter.defaultCenter addObserver:observer
                                           selector:@selector(timeChanged:)
                                               name:@"YTKACEPlaybackTimeDidChange"
                                             object:nil];
}
