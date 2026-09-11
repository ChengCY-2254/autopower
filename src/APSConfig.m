#import "APSConfig.h"

NSString *const APSPrefsSuite      = @"io.cheng.autopower";
NSString *const APSEnabledKey      = @"Enabled";
NSString *const APSIgnoreUserKey   = @"IgnoreUserLowPower";
/* key 字面量 "PluginEnabled" 为历史沿用，与常量名 APSPluginFlagKey / API 名
 * pluginFlagged 不一致；该 key 属内部状态，勿按 key 名新增同名字典项，
 * 否则会静默改写插件对低电量所有权的判断。 */
NSString *const APSPluginFlagKey   = @"PluginEnabled";
NSString *const APSScreenOffModeKey = @"ScreenOffMode";
NSString *const APSLockedModeKey    = @"LockedMode";
NSString *const APSResetRequestKey  = @"ResetRequested";
#ifndef APSLOG_DISABLED
NSString *const APSLogEnabledKey    = @"LogEnabled";
NSString *const APSLogPath          = @"/var/mobile/Library/Preferences/autopower.log";
#endif

NSString *const APSResetNotifName   = @"io.cheng.autopower.reset";

@implementation APSConfig

/* 每个进程缓存同一 suite 的 defaults 实例。 */
+ (NSUserDefaults *)defaults {
    static NSUserDefaults *defaults = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        defaults = [[NSUserDefaults alloc] initWithSuiteName:APSPrefsSuite];
    });
    return defaults;
}

+ (BOOL)prefForKey:(NSString *)key defaultValue:(BOOL)defaultValue {
    id value = [[self defaults] objectForKey:key];
    return value ? [value boolValue] : defaultValue;
}

+ (void)setPref:(BOOL)value forKey:(NSString *)key {
    NSUserDefaults *defaults = [self defaults];
    [defaults setBool:value forKey:key];
    [defaults synchronize];
}

+ (BOOL)enabled {
    return [self prefForKey:APSEnabledKey defaultValue:YES];
}

+ (BOOL)ignoreUserLowPower {
    return [self prefForKey:APSIgnoreUserKey defaultValue:YES];
}

+ (BOOL)screenOffModeEnabled {
    return [self prefForKey:APSScreenOffModeKey defaultValue:NO];  /* 默认模式为锁屏 */
}

+ (BOOL)lockedModeEnabled {
    return [self prefForKey:APSLockedModeKey defaultValue:YES];  /* 安装后默认开启锁屏模式 */
}

+ (BOOL)pluginFlagged {
    return [self prefForKey:APSPluginFlagKey defaultValue:NO];
}

+ (void)setPluginFlagged:(BOOL)on {
    [self setPref:on forKey:APSPluginFlagKey];
}

+ (BOOL)resetRequested {
    return [self prefForKey:APSResetRequestKey defaultValue:NO];
}

+ (void)setResetRequested:(BOOL)on {
    [self setPref:on forKey:APSResetRequestKey];
}

@end
