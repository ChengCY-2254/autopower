//
//  APSConfig.h
//  AutoPower
//
//  配置与内部标志的统一读写层：用户配置与插件内部标志全部经由本类访问。
//
//  线程/时序模型：
//    - 用户配置（enabled / ignoreUserLowPower / 模式开关 / LogEnabled）：
//      任意线程可读（NSUserDefaults 线程安全）；写入方为设置页（Preferences 进程），
//      插件进程内只读；
//    - 内部标志（pluginFlagged / resetRequested）：仅主队列读写（与
//      APSStateMachine 线程模型一致）；持久化仅为跨进程传递（设置页写入
//      resetRequested 触发一键重置）；
//    - 内部标志写入自带 synchronize，调用方无需额外同步。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* 配置域与 key 常量（集中定义，消除散落字符串字面量） */
FOUNDATION_EXPORT NSString *const APSPrefsSuite;
FOUNDATION_EXPORT NSString *const APSEnabledKey;
FOUNDATION_EXPORT NSString *const APSIgnoreUserKey;
FOUNDATION_EXPORT NSString *const APSPluginFlagKey;
FOUNDATION_EXPORT NSString *const APSScreenOffModeKey;
FOUNDATION_EXPORT NSString *const APSLockedModeKey;
FOUNDATION_EXPORT NSString *const APSResetRequestKey;
#ifndef APSLOG_DISABLED
FOUNDATION_EXPORT NSString *const APSLogEnabledKey;
FOUNDATION_EXPORT NSString *const APSLogPath;
#endif

/* Darwin 通知名（一键重置） */
FOUNDATION_EXPORT NSString *const APSResetNotifName;

@interface APSConfig : NSObject

/* 通用读写 */
+ (BOOL)prefForKey:(NSString *)key defaultValue:(BOOL)defaultValue;
+ (void)setPref:(BOOL)value forKey:(NSString *)key;

/* 用户配置语义封装 */
+ (BOOL)enabled;              /* Enabled，默认 YES */
+ (BOOL)ignoreUserLowPower;   /* IgnoreUserLowPower，默认 YES */
+ (BOOL)screenOffModeEnabled; /* ScreenOffMode，默认 NO（默认模式为锁屏） */
+ (BOOL)lockedModeEnabled;    /* LockedMode，默认 YES（安装后默认开启） */

/* 内部标志：插件是否认为低电量模式是自己开启的 */
+ (BOOL)pluginFlagged;
+ (void)setPluginFlagged:(BOOL)on;

/* 一键重置标记（设置页写入，插件下次事件时执行，防通知丢失） */
+ (BOOL)resetRequested;
+ (void)setResetRequested:(BOOL)on;

@end

NS_ASSUME_NONNULL_END
