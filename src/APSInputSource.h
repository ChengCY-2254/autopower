//
//  APSInputSource.h
//  AutoPower
//
//  输入源层：把系统事件（屏幕通知 / 锁屏通知）转成触发态上报给状态机。
//  输入源只负责探测与判定，不参与决策；判定链可通过代际机制整体作废。
//

#import <Foundation/Foundation.h>

#import "APSStateMachine.h"

NS_ASSUME_NONNULL_BEGIN

@class APSStateMachine;

/* 输入源发现 ResetRequested 标记时通知协调者。 */
@protocol APSResetHandling <NSObject>
/* 执行一键重置：作废在途判定、清状态、关闭低电量并重新同步。 */
- (void)performReset;
@end

/* 输入源的统一接口：注册系统通知、初始同步、代际作废。 */
@protocol APSInputSource <NSObject>
@property (nonatomic, readonly) APSInputSourceType type;
/* 注册系统通知；回调统一跳主队列后处理。 */
- (void)registerNotifications;
/* 启动/重置后按当前实际状态向状态机补发一次触发态，避免漏掉已发生的翻转。 */
- (void)syncToStateMachine:(APSStateMachine *)sm;
/* 递增代际，作废所有在途异步判定链。 */
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
@property (nonatomic, weak) id<APSResetHandling> resetDelegate;
@end

NS_ASSUME_NONNULL_END
