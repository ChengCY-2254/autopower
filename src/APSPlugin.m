#import "APSPlugin.h"
#import "APSLog.h"
#import "APSConfig.h"
#import "APSStateMachine.h"
#import "APSInputSource.h"
#import "APSLowPowerProvider.h"
#import "APSScreenProvider.h"
#import "APSLockProvider.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <notify.h>

/* 启动和重置后的同步延迟。 */
static const NSTimeInterval kInitialSyncDelay = 1.0;
static const NSTimeInterval kResetResyncDelay = 1.0;

@interface APSPlugin () <APSResetHandling>
@end

@implementation APSPlugin {
    APSStateMachine *_sm;
    APSScreenInputSource *_screenSource;
    APSLockInputSource *_lockSource;
}

+ (instancetype)shared {
    static APSPlugin *plugin = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        plugin = [APSPlugin new];
    });
    return plugin;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _sm = [APSStateMachine shared];
        _screenSource = [[APSScreenInputSource alloc] initWithStateMachine:_sm];
        _lockSource = [[APSLockInputSource alloc] initWithStateMachine:_sm];
        _screenSource.resetDelegate = self;
    }
    return self;
}

- (void)start {
    /* 外部关闭低电量时清理插件标志。 */
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self, lowPowerNotifyCallback,
        CFSTR("com.apple.system.lowpowermode"), NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self, resetNotifyCallback,
        (__bridge CFStringRef)APSResetNotifName, NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);

    [_screenSource registerNotifications];
    [_lockSource registerNotifications];

    /* 启动时主动同步，避免已有状态没有产生翻转事件。 */
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kInitialSyncDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(self) self = weakSelf;
        if (!self) return;
        [self initialSync];
    });

    APSLog(@"loaded, iOS %@", [UIDevice currentDevice].systemVersion);
    [self runDiagnostics];
}

#pragma mark - 初始同步 / 重置调度

- (void)initialSync {
    APSInputSourceType mode = [APSStateMachine currentModeSource];
    APSLog(@"initial sync: mode=%ld (%@)", (long)mode,
           mode == APSInputSourceScreen ? @"screenOff" :
           (mode == APSInputSourceLock ? @"locked" : @"off"));
    if (mode == APSInputSourceLock) {
        [_lockSource syncToStateMachine:_sm];
    } else if (mode == APSInputSourceScreen) {
        [_screenSource syncToStateMachine:_sm];
    } else {
        APSLog(@"mode off, no auto sync");
    }
}

/* 作废在途判定、清状态、关闭低电量，并按当前模式重新同步。 */
- (void)performReset {
    [_screenSource reset];
    [_lockSource reset];
    [_sm handleReset];

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kResetResyncDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(self) self = weakSelf;
        if (!self) return;
        APSInputSourceType mode = [APSStateMachine currentModeSource];
        APSLog(@"RESET: resync (mode=%ld)", (long)mode);
        if (mode == APSInputSourceLock) {
            [self->_lockSource syncToStateMachine:self->_sm];
        } else if (mode == APSInputSourceScreen) {
            [self->_screenSource syncToStateMachine:self->_sm];
        }
    });
}

#pragma mark - 通知回调

/* Darwin 回调可能在任意线程执行，也可能同步重入；统一切到主队列。 */
static void lowPowerNotifyCallback(CFNotificationCenterRef center, void *observer,
                                   CFStringRef name, const void *object,
                                   CFDictionaryRef userInfo) {
    APSPlugin *plugin = (__bridge APSPlugin *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [plugin->_sm handleExternalLowPowerOff];
    });
}

static void resetNotifyCallback(CFNotificationCenterRef center, void *observer,
                                CFStringRef name, const void *object,
                                CFDictionaryRef userInfo) {
    APSPlugin *plugin = (__bridge APSPlugin *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        APSLog(@"RESET: Darwin notification received");
        [plugin performReset];
    });
}

#pragma mark - 环境诊断

- (void)runDiagnostics {
    APSLog(@"SBBacklightController: %@, _PMLowPowerMode: %@",
           objc_getClass("SBBacklightController") ? @"found" : @"MISSING",
           objc_getClass("_PMLowPowerMode") ? @"found" : @"MISSING");
    APSLog(@"low power provider resolved: %@", [APSLowPowerProviderRegistry currentDescription]);

    /* 只枚举方法清单，不在早期实例化私有单例。 */
#ifndef APSLOG_DISABLED
    [APSScreenProviderRegistry enumerateScreenMethodsForDiagnostics];
    [APSLockProviderRegistry enumerateLockClassesForDiagnostics];
#endif

    APSLog(@"mode config: ScreenOffMode=%d LockedMode=%d (initial)",
           [APSConfig screenOffModeEnabled], [APSConfig lockedModeEnabled]);
}

@end
