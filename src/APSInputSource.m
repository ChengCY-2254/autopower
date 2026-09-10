#import "APSInputSource.h"
#import "APSStateMachine.h"
#import "APSLog.h"
#import "APSConfig.h"
#import "APSScreenProvider.h"
#import "APSLockProvider.h"

#import <UIKit/UIKit.h>
#import <notify.h>

/* 通知只负责触发探测，实际状态由 provider 读取。 */
static const CFStringRef kLockNotifCandidates[] = {
    CFSTR("com.apple.springboard.lockstate"),
    CFSTR("com.apple.springboard.lockcomplete"),
    CFSTR("com.apple.springboard.lockstatechanged"),
    CFSTR("com.apple.springboard.locked"),
    CFSTR("com.apple.springboard.lockstatus"),
    CFSTR("com.apple.springboard.lockScreenDidDismiss"),
    NULL
};

#pragma mark - 判定参数

/* 亮度方向滞回阈值：> 亮阈值 亮，< 灭阈值 灭 */
static const CGFloat kBrightnessOnHysteresis  = 0.05;
static const CGFloat kBrightnessOffHysteresis = 0.02;

/* 通知后的避动画延迟、采样间隔与判断门槛。 */
static const NSTimeInterval kScreenDebounceDelay      = 0.4;
static const NSTimeInterval kBrightnessSampleInterval = 0.15;
static const NSInteger      kBrightnessMajorityCount  = 2;  /* ≥2 次同向才判 */

static const NSTimeInterval kLockDebounceDelay = 0.3;

/* 熄屏检查：1s→3s→7s，最多 3 次。 */
static const NSInteger      kOffConfirmFirstAttempt    = 1;
static const NSInteger      kOffConfirmMaxAttempts     = 3;
static const NSTimeInterval kOffConfirmFirstDelay      = 1.0;   /* 首次复查延迟 */
static const NSTimeInterval kOffConfirmRetryDelayShort = 2.0;   /* attempt 1→2 间隔 */
static const NSTimeInterval kOffConfirmRetryDelayLong  = 4.0;   /* attempt 2→3 间隔 */

/* 亮度方向（采样值区间判定） */
typedef NS_ENUM(NSInteger, ScreenDir) {
    ScreenDirUnknown = -1,
    ScreenDirOff     = 0,
    ScreenDirOn      = 1,
};

#pragma mark - 屏幕输入源

@implementation APSScreenInputSource {
    APSStateMachine *_sm;
    int _notifyToken;

    /* reset 递增代际，使所有在途异步判定失效。 */
    NSUInteger _resolveGeneration;

    BOOL _loggedMissingProvider;
}

- (BOOL)generationCurrent:(NSUInteger)generation {
    return generation == _resolveGeneration;
}

- (instancetype)initWithStateMachine:(APSStateMachine *)stateMachine {
    self = [super init];
    if (self) {
        _sm = stateMachine;
        _notifyToken = 0;
        _resolveGeneration = 0;
    }
    return self;
}

- (APSInputSourceType)type { return APSInputSourceScreen; }

- (void)registerNotifications {
    __weak typeof(self) weakSelf = self;
    uint32_t status = notify_register_dispatch("com.apple.springboard.hasBlankedScreen",
                                               &_notifyToken,
                                               dispatch_get_main_queue(),
                                               ^(int token) {
        __strong typeof(self) self = weakSelf;
        if (!self) return;
        [self screenNotify:token];
    });
    if (status != NOTIFY_STATUS_OK) {
        APSLog(@"hasBlankedScreen notify_register FAILED (%u)", status);
    } else {
        uint64_t st = 0;
        notify_get_state(_notifyToken, &st);
        APSLog(@"hasBlankedScreen registered (token=%d state=%llu)", _notifyToken, st);
    }
}

- (void)screenNotify:(int)token {
    /* SpringBoard 完全运行后才解析私有单例，避免启动早期崩溃。 */
    id<APSScreenProviding> provider = [APSScreenProviderRegistry current];
    if (provider) {
        [provider isUsable];   /* 触发懒解析 + 探测日志 */
    } else if (!_loggedMissingProvider) {
        _loggedMissingProvider = YES;
        APSLog(@"initSbBacklightReader: class MISSING, stay on brightness");
    }

    /* 设置页通知丢失时，在下一次屏幕事件兜底执行重置。 */
    if ([APSConfig resetRequested]) {
        APSLog(@"RESET: pending flag found, executing");
        [self.resetDelegate performReset];
        return;
    }

    uint64_t state = 0;
    notify_get_state(token, &state);
    CGFloat b0 = [UIScreen mainScreen].brightness;

    if ([_sm resolvePendingForSource:APSInputSourceScreen]) {
        APSLog(@"screen notify IGNORED (dup during resolve, state=%llu b0=%.3f)", state, b0);
        return;
    }
    if (![APSConfig enabled]) {
        APSLog(@"screen notify, disabled, skip (state=%llu b0=%.3f)", state, b0);
        return;
    }
    [_sm setResolvePending:YES forSource:APSInputSourceScreen];
    APSLog(@"screen notify -> state=%llu b0=%.3f", state, b0);
    [self beginScreenResolve:state b0:b0];
}

/* 延迟避动画后采样亮度；每个异步步骤都校验代际。 */
- (void)beginScreenResolve:(uint64_t)state b0:(CGFloat)b0 {
    NSUInteger gen = _resolveGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kScreenDebounceDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(self) self = weakSelf;
        if (!self || ![self generationCurrent:gen]) {
            APSLog(@"screen resolve ABANDONED (reset during debounce)");
            return;
        }
        CGFloat v1 = [UIScreen mainScreen].brightness;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBrightnessSampleInterval * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(self) self = weakSelf;
            if (!self || ![self generationCurrent:gen]) {
                APSLog(@"screen resolve ABANDONED (reset during sampling)");
                return;
            }
            CGFloat v2 = [UIScreen mainScreen].brightness;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kBrightnessSampleInterval * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                __strong typeof(self) self = weakSelf;
                if (!self || ![self generationCurrent:gen]) {
                    APSLog(@"screen resolve ABANDONED (reset during sampling)");
                    return;
                }
                CGFloat v3 = [UIScreen mainScreen].brightness;
                [self finishScreenResolve:state b0:b0 v1:v1 v2:v2 v3:v3 generation:gen];
            });
        });
    });
}

static ScreenDir brightnessDir(CGFloat b) {
    if (b > kBrightnessOnHysteresis) return ScreenDirOn;
    if (b < kBrightnessOffHysteresis) return ScreenDirOff;
    return ScreenDirUnknown;
}

/* 亮度主判；熄屏时要求 screenIsOn 双确认。复查期间保持 pending。 */
- (void)finishScreenResolve:(uint64_t)state b0:(CGFloat)b0
                         v1:(CGFloat)v1 v2:(CGFloat)v2 v3:(CGFloat)v3
                 generation:(NSUInteger)gen {
    if (![self generationCurrent:gen]) {
        APSLog(@"screen resolve ABANDONED (reset during sampling)");
        return;
    }
    if (![APSConfig enabled]) {
        [_sm setResolvePending:NO forSource:APSInputSourceScreen];
        return;
    }

    ScreenDir d1 = brightnessDir(v1), d2 = brightnessDir(v2), d3 = brightnessDir(v3);
    int on = (d1 == ScreenDirOn) + (d2 == ScreenDirOn) + (d3 == ScreenDirOn);
    int off = (d1 == ScreenDirOff) + (d2 == ScreenDirOff) + (d3 == ScreenDirOff);
    ScreenDir brightnessDirResult = (on >= kBrightnessMajorityCount) ? ScreenDirOn : ((off >= kBrightnessMajorityCount) ? ScreenDirOff : ScreenDirUnknown);

    id<APSScreenProviding> provider = [APSScreenProviderRegistry current];
    BOOL sbOn = provider ? [provider screenIsOn] : NO;

    ScreenDir dir = brightnessDirResult;
#ifndef APSLOG_DISABLED
    NSString *basis = @"brightness";
#endif

    if (dir == ScreenDirUnknown) {
        APSLog(@"screen resolve UNKNOWN (state=%llu b0=%.3f v=[%.3f,%.3f,%.3f]), keep lastTriggerActive",
               state, b0, v1, v2, v3);
        [_sm setResolvePending:NO forSource:APSInputSourceScreen];
        return;
    }

    /* AOD/过渡期间宁可延迟开启，也不能误开；复查最多 3 次。 */
    if (provider && [provider supportsOffConfirmation] &&
        dir == ScreenDirOff && sbOn &&
        [_sm lastTriggerActiveForSource:APSInputSourceScreen] != APSInputActiveYes) {
        APSLog(@"screen OFF pending screenIsOn=0 confirmation (sbOn=1, AOD/transition?), rechecking...");
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kOffConfirmFirstDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(self) self = weakSelf;
            if (!self || ![self generationCurrent:gen]) {
                APSLog(@"screen OFF confirm ABANDONED (reset during recheck)");
                return;
            }
            [self confirmScreenOff:kOffConfirmFirstAttempt generation:gen];
        });
        return;
    }

    if (provider && [provider isUsable]) {
        BOOL bOn = (dir == ScreenDirOn);
        if (sbOn != bOn) {
            APSLog(@"sbOn=%d conflicts with brightness %@ (AOD/transition?)", sbOn, bOn ? @"ON" : @"OFF");
        }
    }

    [_sm setResolvePending:NO forSource:APSInputSourceScreen];

    BOOL onResult = (dir == ScreenDirOn);
    APSLog(@"screen resolve -> %@ (basis=%@ state=%llu sbOn=%d b0=%.3f v=[%.3f,%.3f,%.3f])",
           onResult ? @"ON" : @"OFF", basis, state, sbOn, b0, v1, v2, v3);

    [_sm handleTriggerActive:!onResult source:APSInputSourceScreen];
}

/* 熄屏双确认复查链。 */
- (void)confirmScreenOff:(int)attempt generation:(NSUInteger)gen {
    if (![self generationCurrent:gen]) {
        APSLog(@"screen OFF confirm ABANDONED (reset during recheck)");
        return;
    }

    if ([APSScreenProviderRegistry brightnessOn]) {
        APSLog(@"screen OFF confirm aborted (screen on during recheck), pending cleared");
        [_sm setResolvePending:NO forSource:APSInputSourceScreen];
        return;
    }

    id<APSScreenProviding> provider = [APSScreenProviderRegistry current];
    if (provider && ![provider screenIsOn]) {
        APSLog(@"screenIsOn now 0 (attempt %d), confirmed OFF -> enable low power", attempt);
        [_sm setResolvePending:NO forSource:APSInputSourceScreen];
        [_sm handleTriggerActive:YES source:APSInputSourceScreen];
        return;
    }
    if (attempt >= kOffConfirmMaxAttempts) {
        APSLog(@"screenIsOn still 1 after 3 attempts (~7s), skip low power ON (AOD?), pending cleared");
        [_sm setResolvePending:NO forSource:APSInputSourceScreen];
        return;
    }
    NSTimeInterval delay = (attempt == kOffConfirmFirstAttempt)
                               ? kOffConfirmRetryDelayShort : kOffConfirmRetryDelayLong;
    APSLog(@"screenIsOn still 1 (attempt %d), recheck in %.0fs", attempt, delay);
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(self) self = weakSelf;
        if (!self || ![self generationCurrent:gen]) {
            APSLog(@"screen OFF confirm ABANDONED (reset during recheck)");
            return;
        }
        [self confirmScreenOff:attempt + 1 generation:gen];
    });
}

- (void)syncToStateMachine:(APSStateMachine *)sm {
    BOOL on = [APSScreenProviderRegistry brightnessOn];
    [sm handleTriggerActive:!on source:APSInputSourceScreen];
}

- (void)reset {
    _resolveGeneration++;
}

@end

#pragma mark - 锁屏输入源

@implementation APSLockInputSource {
    APSStateMachine *_sm;

    /* reset 递增代际，使在途防抖链失效。 */
    NSUInteger _resolveGeneration;
}

- (instancetype)initWithStateMachine:(APSStateMachine *)stateMachine {
    self = [super init];
    if (self) {
        _sm = stateMachine;
        _resolveGeneration = 0;
    }
    return self;
}

- (APSInputSourceType)type { return APSInputSourceLock; }

- (void)registerNotifications {
    /* 锁屏通知候选全部注册，收到任一即触发状态复查。 */
    for (int i = 0; kLockNotifCandidates[i]; i++) {
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge const void *)self, lockNotifyCallback, kLockNotifCandidates[i], NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}

/* 锁屏通知回调：触发锁屏状态复查（锁屏模式专用）。
 * 线程约束：Darwin 通知回调不保证在主线程，统一跳主队列后再处理——
 * 与状态机/输入源的"全主队列"串行约定一致，避免跨线程访问与同步重入。 */
static void lockNotifyCallback(CFNotificationCenterRef center, void *observer,
                               CFStringRef name, const void *object,
                               CFDictionaryRef userInfo) {
    APSLockInputSource *self = (__bridge APSLockInputSource *)observer;
    NSString *notifName = (__bridge NSString *)name;   /* block 捕获强引用，保证回调参数生命周期 */
    dispatch_async(dispatch_get_main_queue(), ^{
        [self handleLockNotify:notifName];
    });
}

- (void)handleLockNotify:(NSString *)notifName {
    [APSLockProviderRegistry ensureInitialized];
    APSLog(@"lock notify received: %@", notifName);

    if (![APSLockProviderRegistry current]) {
        APSLog(@"lock notify: reader not usable, no action");
        return;
    }
    if (![APSConfig enabled]) {
        APSLog(@"lock notify, disabled, skip");
        return;
    }
    if ([APSStateMachine currentModeSource] != APSInputSourceLock) {
        APSLog(@"lock notify: not in locked mode, observe only");
        return;
    }
    if ([_sm resolvePendingForSource:APSInputSourceLock]) {
        APSLog(@"lock notify IGNORED (dup during resolve)");
        return;
    }
    [_sm setResolvePending:YES forSource:APSInputSourceLock];
    /* 防抖链捕获代际：reset 后该链作废，不再上报 */
    NSUInteger gen = _resolveGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kLockDebounceDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(self) self = weakSelf;
        if (!self || gen != self->_resolveGeneration) {
            APSLog(@"lock resolve ABANDONED (reset during debounce)");
            return;
        }
        [self finishLockResolve];
    });
}

- (void)finishLockResolve {
    [_sm setResolvePending:NO forSource:APSInputSourceLock];
    APSLockStatus st = [[APSLockProviderRegistry current] lockStatus];
    if (st == APSLockStatusTransient) {
        /* 过渡态（通知栏/CoverSheet 遮罩）：保持上次状态，不翻转 */
        APSLog(@"lock resolve TRANSIENT, keep last=%ld", (long)[_sm lastTriggerActiveForSource:APSInputSourceLock]);
        return;
    }
    if (st == APSLockStatusUnknown) {
        APSLog(@"lock resolve UNKNOWN, keep last=%ld", (long)[_sm lastTriggerActiveForSource:APSInputSourceLock]);
        return;
    }
    BOOL locked = (st == APSLockStatusLocked);
#ifndef APSLOG_DISABLED
    [APSLockProviderRegistry logAuxSignals];
#endif
    APSLog(@"lock resolve -> %@ (last=%ld)", locked ? @"LOCKED" : @"UNLOCKED",
           (long)[_sm lastTriggerActiveForSource:APSInputSourceLock]);
    [_sm handleTriggerActive:locked source:APSInputSourceLock];
}

- (void)syncToStateMachine:(APSStateMachine *)sm {
    [APSLockProviderRegistry ensureInitialized];
    APSLockStatus st = [[APSLockProviderRegistry current] lockStatus];
    if (st == APSLockStatusTransient) {
        APSLog(@"lastLocked init: lock transient, keep last=%ld", (long)[sm lastTriggerActiveForSource:APSInputSourceLock]);
        return;
    }
    if (st == APSLockStatusUnknown) {
        APSLog(@"lastLocked init: lock unknown, keep last=%ld", (long)[sm lastTriggerActiveForSource:APSInputSourceLock]);
        return;
    }
    BOOL locked = (st == APSLockStatusLocked);
    [sm handleTriggerActive:locked source:APSInputSourceLock];
}

- (void)reset {
    /* 作废在途 0.3s 防抖链；无其他持久观测状态 */
    _resolveGeneration++;
}

@end
