#import "APSScreenProvider.h"
#import "APSLog.h"
#import "APSGuard.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

/* 亮度判亮阈值：> 0.02 视为屏幕亮（与判定层的滞回阈值分离，此处为单一判定信源） */
const CGFloat kBrightnessActiveThreshold = 0.02;

#pragma mark - 私有 API

/* 单例方法均运行时探测后再调用。 */
@interface SBBacklightController : NSObject
+ (instancetype)sharedInstance;
+ (instancetype)shared;
+ (instancetype)sharedController;
+ (instancetype)instance;
- (BOOL)screenIsOn;
- (BOOL)screenIsDim;
@end

#pragma mark - 适配器

@implementation APSSBBacklightProvider {
    SBBacklightController *_backlight;
    BOOL _usable;
}

+ (BOOL)isAvailable {
    return objc_getClass("SBBacklightController") != NULL;
}

/* 延迟到首次读取时解析，避免 SpringBoard 启动早期调用私有单例。 */
- (void)ensureInitialized {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @autoreleasepool {
            Class cls = objc_getClass("SBBacklightController");
            if (!cls) {
                APSLog(@"initSbBacklightReader: class MISSING, stay on brightness");
                return;
            }
            SEL singletonSels[] = {
                @selector(sharedInstance), @selector(shared),
                @selector(sharedController), @selector(instance), NULL
            };
            for (int i = 0; singletonSels[i] != NULL; i++) {
                if ([(id)cls respondsToSelector:singletonSels[i]]) {
                    id maybe = ((id (*)(id, SEL))(void *)objc_msgSend)((id)cls, singletonSels[i]);
                    if (maybe && [maybe isKindOfClass:cls]) {
                        _backlight = maybe;
                        APSLog(@"initSbBacklightReader: singleton via %@", NSStringFromSelector(singletonSels[i]));
                        break;
                    } else {
                        APSLog(@"initSbBacklightReader: %@ returned invalid instance, try next",
                               NSStringFromSelector(singletonSels[i]));
                    }
                }
            }
            if (!_backlight) {
                APSLog(@"initSbBacklightReader: singleton MISSING/invalid, stay on brightness");
                return;
            }
            if ([_backlight respondsToSelector:@selector(screenIsOn)]) {
                _usable = YES;
                APSLog(@"initSbBacklightReader: screenIsOn usable");
            } else {
                APSLog(@"initSbBacklightReader: screenIsOn MISSING, stay on brightness");
            }
        }
    });
}

- (BOOL)isUsable {
    [self ensureInitialized];
    return _usable;
}

- (BOOL)screenIsOn {
    [self ensureInitialized];
    if (!_usable) return NO;
    BOOL failed = NO;
    BOOL on = APSGuardCallBool(@"sbScreenIsOn", NO, &failed, ^{
        return [_backlight screenIsOn];
    });
    if (failed) {
        _usable = NO;   /* 该信源异常，永久回退亮度 */
        APSLog(@"sbScreenIsOn failed, fallback to brightness");
    }
    return on;
}

- (BOOL)supportsOffConfirmation {
    return [self isUsable];
}

@end

#pragma mark - 注册表

@implementation APSScreenProviderRegistry

+ (id<APSScreenProviding>)current {
    static id<APSScreenProviding> provider = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        /* 无可用 provider 时由输入源使用亮度兜底。 */
        if ([APSSBBacklightProvider isAvailable]) {
            provider = [APSSBBacklightProvider new];
        }
    });
    return provider;
}

+ (BOOL)brightnessOn {
    return [UIScreen mainScreen].brightness > kBrightnessActiveThreshold;
}

/* 诊断可用的屏幕状态读取方法。 */
#ifndef APSLOG_DISABLED
+ (void)enumerateScreenMethodsForDiagnostics {
    Class sbbl = objc_getClass("SBBacklightController");
    if (!sbbl) return;
    unsigned int mc = 0;
    Method *methods = class_copyMethodList(sbbl, &mc);
    NSMutableArray *screenish = [NSMutableArray array];
    for (unsigned int i = 0; i < mc; i++) {
        const char *name = sel_getName(method_getName(methods[i]));
        NSString *s = [NSString stringWithUTF8String:name];
        if ([s rangeOfString:@"screen"  options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [s rangeOfString:@"backlight" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [s rangeOfString:@"blank"    options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [s rangeOfString:@"isOn"     options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [s rangeOfString:@"state"    options:NSCaseInsensitiveSearch].location != NSNotFound) {
            [screenish addObject:s];
        }
    }
    free(methods);
    APSLog(@"SBBacklightController screen-related methods (%lu): %@",
           (unsigned long)[screenish count], screenish);
}
#endif

@end
