//
//  APSScreenProvider.h
//  AutoPower
//
//  屏幕状态能力层：读取屏幕是否点亮。优先使用 SBBacklightController 私有 API，
//  不可用时由调用方回退到亮度阈值判断。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* 亮度兜底信源的判亮阈值。 */
FOUNDATION_EXPORT const CGFloat kBrightnessActiveThreshold;

@protocol APSScreenProviding <NSObject>
/* 屏幕是否点亮。读取失败时返回 NO 并内部永久回退亮度。 */
- (BOOL)screenIsOn;
/* 该信源当前是否可用（私有单例解析成功且读取方法存在）。 */
- (BOOL)isUsable;
/* 熄屏结果是否需要用 screenIsOn 双确认：仅可信信源返回 YES，
 * 亮度兜底信源返回 NO，避免用同一路亮度信号自我确认。 */
- (BOOL)supportsOffConfirmation;
@end

/* SBBacklightController 适配器。 */
@interface APSSBBacklightProvider : NSObject <APSScreenProviding>
+ (BOOL)isAvailable;
@end

/* 注册表：惰性解析并缓存可用 provider；无可用者时返回 nil，由调用方走亮度兜底。 */
@interface APSScreenProviderRegistry : NSObject
+ (id<APSScreenProviding>)current;
/* 亮度兜底判亮（单一阈值，不做滞回）。 */
+ (BOOL)brightnessOn;
#ifndef APSLOG_DISABLED
+ (void)enumerateScreenMethodsForDiagnostics;
#endif
@end

NS_ASSUME_NONNULL_END
