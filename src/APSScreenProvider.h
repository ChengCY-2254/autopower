#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* 亮度兜底信源的判亮阈值。 */
FOUNDATION_EXPORT const CGFloat kBrightnessActiveThreshold;

@protocol APSScreenProviding <NSObject>
	- (BOOL)screenIsOn;
	- (BOOL)isUsable;
	- (BOOL)supportsOffConfirmation;
@end

/* SBBacklightController 适配器。 */
@interface APSSBBacklightProvider : NSObject <APSScreenProviding>
	+ (BOOL)isAvailable;
@end

@interface APSScreenProviderRegistry : NSObject
	+ (id<APSScreenProviding>)current;
	+ (BOOL)brightnessOn;
#ifndef APSLOG_DISABLED
	+ (void)enumerateScreenMethodsForDiagnostics;
#endif
@end

NS_ASSUME_NONNULL_END
