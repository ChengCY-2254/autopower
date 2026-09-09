//
//  APSLowPowerProvider.h
//  AutoPower
//
// 低电量模式读写能力层：封装 iOS 18 私有 API
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol APSLowPowerProviding <NSObject>
- (BOOL)isLowPowerOn;
- (void)setLowPowerOn:(BOOL)on;
@optional
+ (NSString *)providerName;   /* 诊断 */
@end

/* _PMLowPowerMode（iOS 18） */
@interface APSPMLowPowerProvider : NSObject <APSLowPowerProviding>
+ (BOOL)isAvailable;
@end

/* 注册表：惰性解析并缓存 iOS 18 provider */
@interface APSLowPowerProviderRegistry : NSObject
+ (id<APSLowPowerProviding>)current;
+ (NSString *)currentDescription;   /* 诊断：当前生效 provider 名 */
@end

NS_ASSUME_NONNULL_END
