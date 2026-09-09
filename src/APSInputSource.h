#import <Foundation/Foundation.h>

#import "APSStateMachine.h"

NS_ASSUME_NONNULL_BEGIN

@class APSStateMachine;

/* 输入源发现 ResetRequested 标记时通知协调者。 */
@protocol APSResetHandling <NSObject>
	- (void)performReset;
@end

@protocol APSInputSource <NSObject>
@property (nonatomic, readonly) APSInputSourceType type;
	- (void)registerNotifications;
	- (void)syncToStateMachine:(APSStateMachine *)sm;
	- (void)reset;
@end

/* 屏幕通知、亮度采样与 SBBacklight 双确认。 */
@interface APSScreenInputSource : NSObject <APSInputSource>
- (instancetype)initWithStateMachine:(APSStateMachine *)stateMachine;
@property (nonatomic, weak) id<APSResetHandling> resetDelegate;
@end

/* 锁屏通知与 provider 判定。 */
@interface APSLockInputSource : NSObject <APSInputSource>
- (instancetype)initWithStateMachine:(APSStateMachine *)stateMachine;
@end

NS_ASSUME_NONNULL_END
