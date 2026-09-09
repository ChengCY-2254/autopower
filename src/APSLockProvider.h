//
//  APSLockProvider.h
//  AutoPower
//
//  锁屏状态能力层：屏蔽 iOS 版本差异的私有 API（运行时探测，不猜类/方法名）。
//
//  现有适配器：
//    APSAggregatorLockProvider → SBLockStateAggregator.lockState（主判：
//      3=真锁屏 → Locked；0=解锁 → Unlocked；1=通知栏/CoverSheet 遮罩 → Transient）
//    APSUILockProvider         → SBLockScreenManager 的 BOOL 方法回退链
//      （isUILocked → isLocked → isDeviceLocked → isLockScreenActive → isLockScreenVisible）
//
//  安全约束与低电量层相同：私有单例惰性解析，禁止在 %ctor 早期调用。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, APSLockStatus) {
    APSLockStatusUnknown   = -1,   /* 未知（信源不可用/异常） */
    APSLockStatusUnlocked  = 0,    /* 解锁 */
    APSLockStatusLocked    = 1,    /* 锁定（Face ID 未解锁，含锁屏界面/AOD） */
    APSLockStatusTransient = 2,    /* 通知栏/CoverSheet 遮罩：保持上次状态 */
};

@protocol APSLockProviding <NSObject>
- (BOOL)isUsable;
- (APSLockStatus)lockStatus;
@end

@interface APSAggregatorLockProvider : NSObject <APSLockProviding>
+ (BOOL)isAvailable;
@end

/* SBLockScreenManager 的 BOOL 方法回退链 */
@interface APSUILockProvider : NSObject <APSLockProviding>
+ (BOOL)isAvailable;
@end

@interface APSLockProviderRegistry : NSObject
+ (void)ensureInitialized;                    /* 惰性解析（首次收到锁屏通知时执行） */
+ (id<APSLockProviding>)current;              /* aggregator 优先，UILock 次之；nil = 不可用 */
#ifndef APSLOG_DISABLED
+ (void)logAuxSignals;                        /* 辅助信号诊断 */
+ (void)enumerateLockClassesForDiagnostics;   /* %ctor 只查询不实例化 */
#endif
@end

NS_ASSUME_NONNULL_END
