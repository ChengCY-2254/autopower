#import "APSLockProvider.h"
#import "APSLog.h"
#import "APSGuard.h"
#import "APSScreenProvider.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - 私有 API

/* 类、方法和单例均运行时探测后调用。 */
@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstance;
+ (instancetype)shared;
+ (instancetype)sharedManager;
+ (instancetype)instance;
- (BOOL)isLocked;
- (BOOL)isDeviceLocked;
- (int64_t)lockScreenState;
- (BOOL)isUILocked;
- (BOOL)isLockScreenActive;
- (BOOL)isLockScreenVisible;
- (int64_t)lockState;
- (BOOL)hasAnyLockState;
@end

@interface SBLockStateAggregator : NSObject
+ (instancetype)sharedInstance;
+ (instancetype)shared;
+ (instancetype)sharedManager;
+ (instancetype)instance;
- (int64_t)lockState;
- (BOOL)hasAnyLockState;
@end

#pragma mark - 状态值

/* SBLockStateAggregator.lockState 数值语义：
 * 3=真锁屏（Face ID 未解锁）→ Locked；0=解锁 → Unlocked；其余为过渡态 */
static const int64_t kAggregatorLockStateLocked   = 3;
static const int64_t kAggregatorLockStateUnlocked = 0;

/* 辅助信号诊断哨兵值（log only，标识"信号缺失/未读取"，无语义） */
static const int64_t kAuxSignalSentinel = -999;
#ifndef APSLOG_DISABLED
static const int      kAuxBoolSentinel  = -1;
#endif

#pragma mark - SBLockStateAggregator 适配器（主判）

@implementation APSAggregatorLockProvider {
    SBLockStateAggregator *_aggregator;
    BOOL _usable;
}

+ (BOOL)isAvailable {
    return objc_getClass("SBLockStateAggregator") != NULL;
}

- (void)ensureInitialized {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @autoreleasepool {
            Class cls = objc_getClass("SBLockStateAggregator");
            if (!cls) return;
            SEL singletonSels[] = {
                @selector(sharedInstance), @selector(shared),
                @selector(sharedManager), @selector(instance), NULL
            };
            for (int k = 0; singletonSels[k] != NULL && !_aggregator; k++) {
                if ([(id)cls respondsToSelector:singletonSels[k]]) {
                    id maybe = ((id (*)(id, SEL))(void *)objc_msgSend)((id)cls, singletonSels[k]);
                    if (maybe && [maybe isKindOfClass:cls]) {
                        _aggregator = maybe;
                        APSLog(@"initLockReader: SBLockStateAggregator via %@",
                               NSStringFromSelector(singletonSels[k]));
                    }
                }
            }
            if (!_aggregator) {
                APSLog(@"initLockReader: SBLockStateAggregator singleton MISSING");
                return;
            }
            if ([_aggregator respondsToSelector:@selector(lockState)]) {
                _usable = YES;
            } else {
                APSLog(@"initLockReader: SBLockStateAggregator lockState MISSING");
            }
        }
    });
}

- (BOOL)isUsable {
    [self ensureInitialized];
    return _usable;
}

- (APSLockStatus)lockStatus {
    if (![self isUsable]) return APSLockStatusUnknown;
    BOOL failed = NO;
    int64_t v = APSGuardCallInt64(@"aggregator lockState", kAuxSignalSentinel, &failed, ^{
        return (int64_t)[_aggregator lockState];
    });
    if (failed) {
        _usable = NO;   /* 信源异常，永久禁用，回退 UILock/不可用 */
        APSLog(@"aggregator lockStatus failed, aggregator disabled");
        return APSLockStatusUnknown;
    }
    if (v == kAggregatorLockStateLocked) return APSLockStatusLocked;
    if (v == kAggregatorLockStateUnlocked) return APSLockStatusUnlocked;
    APSLog(@"lockState transient value=%lld (notification center / cover sheet?), keep last", v);
    return APSLockStatusTransient;
}

#ifndef APSLOG_DISABLED
- (void)logAggregatorSignal {
    if (!_aggregator) return;
    if (![_aggregator respondsToSelector:@selector(lockState)]) return;
    int64_t aggLockState = APSGuardCallInt64(@"logAggregatorSignal lockState", kAuxSignalSentinel, NULL, ^{
        return (int64_t)[_aggregator lockState];
    });
    APSLog(@"lock aux: aggLockState=%lld", aggLockState);
}
#endif

@end

#pragma mark - SBLockScreenManager 适配器（BOOL 方法回退链）

@implementation APSUILockProvider {
    SBLockScreenManager *_manager;
    BOOL _isUILockedUsable;
    BOOL _isLockedUsable;
    BOOL _isDeviceLockedUsable;
    BOOL _isLockScreenActiveUsable;
    BOOL _isLockScreenVisibleUsable;
    BOOL _lockScreenStateUsable;   /* 数值语义未参与判定：仅日志 */
    BOOL _lockStateUsable;         /* 数值语义未参与判定：仅日志 */
}

+ (BOOL)isAvailable {
    return objc_getClass("SBLockScreenManager") != NULL;
}

/* 优先使用语义明确的 BOOL 方法。 */
- (void)ensureInitialized {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @autoreleasepool {
            Class candidates[] = {
                objc_getClass("SBLockScreenManager"),
                objc_getClass("SBLockStateAggregator"),
                objc_getClass("SBLockScreenController"),
                objc_getClass("SBLockScreenViewController"),
                NULL
            };
            SEL singletonSels[] = {
                @selector(sharedInstance), @selector(shared),
                @selector(sharedManager), @selector(instance), NULL
            };
            for (int i = 0; candidates[i] && !_manager; i++) {
                Class cls = candidates[i];
                for (int k = 0; singletonSels[k] != NULL; k++) {
                    if ([(id)cls respondsToSelector:singletonSels[k]]) {
                        id maybe = ((id (*)(id, SEL))(void *)objc_msgSend)((id)cls, singletonSels[k]);
                        if (maybe && [maybe isKindOfClass:cls]) {
                            _manager = maybe;
                            APSLog(@"initLockReader: singleton via %@ on %@",
                                   NSStringFromSelector(singletonSels[k]),
                                   NSStringFromClass(cls));
                            break;
                        }
                    }
                }
            }
            if (!_manager) {
                APSLog(@"initLockReader: no lock manager resolved, locked mode INACTIVE");
                return;
            }
            if ([_manager respondsToSelector:@selector(isUILocked)]) {
                _isUILockedUsable = YES;
                APSLog(@"initLockReader: -isUILocked usable");
            }
            if ([_manager respondsToSelector:@selector(isLocked)]) {
                _isLockedUsable = YES;
                APSLog(@"initLockReader: -isLocked usable");
            }
            if ([_manager respondsToSelector:@selector(isDeviceLocked)]) {
                _isDeviceLockedUsable = YES;
                APSLog(@"initLockReader: -isDeviceLocked usable");
            }
            if ([_manager respondsToSelector:@selector(isLockScreenActive)]) {
                _isLockScreenActiveUsable = YES;
                APSLog(@"initLockReader: -isLockScreenActive usable");
            }
            if ([_manager respondsToSelector:@selector(isLockScreenVisible)]) {
                _isLockScreenVisibleUsable = YES;
                APSLog(@"initLockReader: -isLockScreenVisible usable");
            }
            if ([_manager respondsToSelector:@selector(lockScreenState)]) {
                _lockScreenStateUsable = YES;
                APSLog(@"initLockReader: -lockScreenState usable (semantics TBD by logs)");
            }
            if ([_manager respondsToSelector:@selector(lockState)]) {
                _lockStateUsable = YES;
                APSLog(@"initLockReader: -lockState usable (semantics TBD by logs)");
            }
        }
    });
}

- (BOOL)isUsable {
    [self ensureInitialized];
    return _isUILockedUsable || _isLockedUsable || _isDeviceLockedUsable ||
           _isLockScreenActiveUsable || _isLockScreenVisibleUsable;
}

- (BOOL)managerResolved {
    return _manager != nil;
}

- (APSLockStatus)lockStatus {
    if (![self isUsable]) return APSLockStatusUnknown;
    BOOL failed = NO;
    APSLockStatus status = (APSLockStatus)APSGuardCallInt64(@"deviceLocked", APSLockStatusUnknown, &failed, ^{
        if (_isUILockedUsable) return [_manager isUILocked] ? APSLockStatusLocked : APSLockStatusUnlocked;
        if (_isLockedUsable) return [_manager isLocked] ? APSLockStatusLocked : APSLockStatusUnlocked;
        if (_isDeviceLockedUsable) return [_manager isDeviceLocked] ? APSLockStatusLocked : APSLockStatusUnlocked;
        if (_isLockScreenActiveUsable) return [_manager isLockScreenActive] ? APSLockStatusLocked : APSLockStatusUnlocked;
        if (_isLockScreenVisibleUsable) return [_manager isLockScreenVisible] ? APSLockStatusLocked : APSLockStatusUnlocked;
        /* 防御分支：无可用 BOOL 方法时仅输出数值信号原始值（语义未知，log only） */
#ifndef APSLOG_DISABLED
        if (_lockScreenStateUsable) {
            int64_t v = (int64_t)[_manager lockScreenState];
            APSLog(@"lockScreenState raw value: %lld (semantics unknown, log only)", v);
        }
        if (_lockStateUsable) {
            int64_t v = (int64_t)[_manager lockState];
            APSLog(@"lockState raw value: %lld (semantics unknown, log only)", v);
        }
#endif
        return APSLockStatusUnknown;
    });
    if (failed) {
        APSLog(@"deviceLocked failed, lock reader disabled");
        [self disable];
        return APSLockStatusUnknown;
    }
    return status;
}

- (void)disable {
    _isUILockedUsable = _isLockedUsable = _isDeviceLockedUsable = NO;
    _isLockScreenActiveUsable = _isLockScreenVisibleUsable = NO;
}

#ifndef APSLOG_DISABLED
- (void)logManagerSignals {
    if (!_manager) return;
    __block int uiLocked = kAuxBoolSentinel, vis = kAuxBoolSentinel, active = kAuxBoolSentinel;
    __block int64_t lockState = kAuxSignalSentinel, hasAny = kAuxSignalSentinel;
    BOOL failed = NO;
    APSGuardCallVoid(@"logManagerSignals", &failed, ^{
        if ([_manager respondsToSelector:@selector(isUILocked)]) uiLocked = [_manager isUILocked] ? 1 : 0;
        if ([_manager respondsToSelector:@selector(isLockScreenVisible)]) vis = [_manager isLockScreenVisible] ? 1 : 0;
        if ([_manager respondsToSelector:@selector(isLockScreenActive)]) active = [_manager isLockScreenActive] ? 1 : 0;
        if ([_manager respondsToSelector:@selector(lockState)]) lockState = (int64_t)[_manager lockState];
        if ([_manager respondsToSelector:@selector(hasAnyLockState)]) hasAny = [_manager hasAnyLockState] ? 1 : 0;
    });
    APSLog(@"lock aux: uiLocked=%d lockScreenVisible=%d lockScreenActive=%d "
           @"mgrLockState=%lld hasAny=%lld",
           uiLocked, vis, active, lockState, hasAny);
}
#endif

@end

#pragma mark - 注册表

/* 文件内私有扩展：registry 与 provider 同文件协作所需 */
@interface APSUILockProvider (Private)
- (void)ensureInitialized;
- (BOOL)managerResolved;
#ifndef APSLOG_DISABLED
- (void)logManagerSignals;
#endif
@end

@interface APSAggregatorLockProvider (Private)
- (void)ensureInitialized;
#ifndef APSLOG_DISABLED
- (void)logAggregatorSignal;
#endif
@end

@implementation APSLockProviderRegistry {
    APSAggregatorLockProvider *_aggregator;
    APSUILockProvider *_uiLock;
    BOOL _initialized;
}

+ (instancetype)sharedRegistry {
    static APSLockProviderRegistry *registry = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        registry = [APSLockProviderRegistry new];
    });
    return registry;
}

/* 惰性解析（首次收到锁屏通知时执行）。
 * 保序：先解析 lock manager（失败则整个锁屏信源不可用），成功后才解析 aggregator。
 * 线程约束：仅在主队列调用（锁屏通知回调已跳主队列，见 APSInputSource.m）；
 * 串行性由"全主队列"约定保证，_initialized 无需加锁。 */
- (void)ensureInitialized {
    if (_initialized) return;
    _initialized = YES;
    @autoreleasepool {
        _uiLock = [APSUILockProvider new];
        [_uiLock ensureInitialized];
        if (!_uiLock.managerResolved) {
            return;   /* no lock manager → 整个锁屏信源不可用，不解析 aggregator */
        }
        _aggregator = [APSAggregatorLockProvider new];
        [_aggregator ensureInitialized];
    }
}

- (id<APSLockProviding>)current {
    [self ensureInitialized];
    if (![_uiLock isUsable]) return nil;   /* 无可用 BOOL 方法：整个锁屏不可用 */
    if (_aggregator && [_aggregator isUsable]) return _aggregator;
    return _uiLock;
}

#ifndef APSLOG_DISABLED
- (void)logAuxSignals {
    [self ensureInitialized];
    APSGuardCallVoid(@"logLockAuxSignals", NULL, ^{
        [_uiLock logManagerSignals];
        [_aggregator logAggregatorSignal];
        APSLog(@"lock aux: brightnessOn=%d", [UIScreen mainScreen].brightness > kBrightnessActiveThreshold ? 1 : 0);
    });
}
#endif

+ (void)ensureInitialized { [[self sharedRegistry] ensureInitialized]; }
+ (id<APSLockProviding>)current { return [[self sharedRegistry] current]; }
#ifndef APSLOG_DISABLED
+ (void)logAuxSignals { [[self sharedRegistry] logAuxSignals]; }

/* %ctor 诊断：枚举候选类所有 lock 相关方法名写日志（只查询不实例化）。 */
+ (void)enumerateLockClassesForDiagnostics {
    Class candidates[] = {
        objc_getClass("SBLockScreenManager"),
        objc_getClass("SBLockStateAggregator"),
        objc_getClass("SBLockScreenController"),
        objc_getClass("SBLockScreenViewController"),
        objc_getClass("SpringBoard"),
        NULL
    };
    for (int i = 0; candidates[i]; i++) {
        Class cls = candidates[i];
        if (!cls) continue;
        unsigned int mc = 0;
        Method *methods = class_copyMethodList(cls, &mc);
        NSMutableArray *lockish = [NSMutableArray array];
        for (unsigned int j = 0; j < mc; j++) {
            const char *name = sel_getName(method_getName(methods[j]));
            NSString *s = [NSString stringWithUTF8String:name];
            if ([s rangeOfString:@"lock" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [s rangeOfString:@"Locked"].location != NSNotFound ||
                [s rangeOfString:@"unlock" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [s rangeOfString:@"authentication" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [s rangeOfString:@"notification center" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [s rangeOfString:@"NotificationCenter"].location != NSNotFound ||
                [s rangeOfString:@"cover sheet" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [s rangeOfString:@"CoverSheet"].location != NSNotFound) {
                [lockish addObject:s];
            }
        }
        free(methods);
        APSLog(@"lock classes: %@ (%lu lock-related methods): %@",
               NSStringFromClass(cls), (unsigned long)lockish.count, lockish);
    }
}
#endif

@end
