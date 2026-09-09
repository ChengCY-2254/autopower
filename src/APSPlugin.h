//
//  APSPlugin.h
//  AutoPower
//
//  装配协调者：%ctor 的职责集中于此（通知注册、初始同步、重置调度、环境诊断）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface APSPlugin : NSObject
+ (instancetype)shared;
- (void)start;   /* %ctor 装配入口 */
@end

NS_ASSUME_NONNULL_END
