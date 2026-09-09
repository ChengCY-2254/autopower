#import "APSLowPowerProvider.h"
#import "APSLog.h"
#import "APSGuard.h"

#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - 私有 API

@interface _PMLowPowerMode : NSObject
+ (instancetype)sharedInstance;
+ (instancetype)shared;
+ (instancetype)sharedManager;
+ (instancetype)instance;
+ (instancetype)singleton;
- (int64_t)getPowerMode;
- (void)setPowerMode:(int64_t)mode fromSource:(id)source;
@end

#pragma mark - _PMLowPowerMode

@implementation APSPMLowPowerProvider

+ (NSString *)providerName { return @"_PMLowPowerMode"; }

+ (BOOL)isAvailable {
    return objc_getClass("_PMLowPowerMode") != NULL;
}

/* 单例不可用时回退到 alloc/init。 */
- (_PMLowPowerMode *)manager {
    static _PMLowPowerMode *instance = nil;
    if (instance) return instance;
    Class cls = objc_getClass("_PMLowPowerMode");
    if (!cls) return nil;
    SEL singletonSels[] = {
        @selector(sharedInstance), @selector(shared), @selector(sharedManager),
        @selector(instance), @selector(singleton), NULL
    };
    for (int i = 0; singletonSels[i] != NULL; i++) {
        if (class_respondsToSelector(cls, singletonSels[i])) {
            id maybe = ((id (*)(id, SEL))(void *)objc_msgSend)((id)cls, singletonSels[i]);
            if (maybe && [maybe isKindOfClass:cls]) {
                instance = maybe;
                break;
            }
        }
    }
    if (!instance) instance = [[cls alloc] init];
    APSLog(@"_PMLowPowerMode instance: %@", instance ? @"acquired" : @"nil");
    return instance;
}

- (BOOL)isLowPowerOn {
    _PMLowPowerMode *mgr = [self manager];
    if (!mgr) return NO;
    BOOL failed = NO;
    int64_t mode = APSGuardCallInt64(@"getPowerMode", 0, &failed, ^{
        return [mgr getPowerMode];
    });
    if (failed) APSLog(@"getPowerMode failed, assuming low power OFF");
    return mode != 0;
}

- (void)setLowPowerOn:(BOOL)on {
    _PMLowPowerMode *mgr = [self manager];
    if (!mgr) return;
    APSLog(@"setPowerMode:%d via _PMLowPowerMode", on ? 1 : 0);
    BOOL failed = NO;
    APSGuardCallVoid(@"setPowerMode", &failed, ^{
        [mgr setPowerMode:on ? 1 : 0 fromSource:@"io.cheng.autopower"];
    });
    if (failed) APSLog(@"setPowerMode failed, low power state unchanged");
}

@end

#pragma mark - 注册表

@implementation APSLowPowerProviderRegistry

+ (id<APSLowPowerProviding>)current {
    static id<APSLowPowerProviding> provider = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class candidates[] = {
            [APSPMLowPowerProvider class],
            NULL
        };
        for (int i = 0; candidates[i] != NULL; i++) {
            if ([candidates[i] isAvailable]) {
                provider = [candidates[i] new];
                APSLog(@"low power provider: %@", NSStringFromClass(candidates[i]));
                break;
            }
        }
    });
    return provider;
}

+ (NSString *)currentDescription {
    id<APSLowPowerProviding> p = [self current];
    return p ? NSStringFromClass([p class]) : @"none";
}

@end
