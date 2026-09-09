//
//  APSStateMachine.h
//  AutoPower
//
//  统一状态机：收敛所有决策状态与分散 flag。输入源只上报触发态（屏幕灭 /
//  设备锁定），本层负责去抖记忆、模式匹配与"开省电 / 关省电 / 保留用户开启"
//  的统一决策。内部状态：lastTriggerActive（去抖记忆）、resolvePending（判定
//  进行中，按输入源分开）；pluginFlag 属配置层，由本层决策后写入。
//
//  纯函数化（决策与副作用分离）：入口方法固定按
//  snapshotContext（快照配置 / 省电状态 / 触发模式）→ APSDecide*（纯决策，
//  禁止 IO / 配置读写 / 日志）→ applyDecision（映射为副作用：provider 开关、
//  配置写入、日志）执行。追踪任一入口只需读这三个函数的顺序调用。
//
//  线程模型（全插件统一约定）：所有方法必须从主队列调用，内部不加锁；
//  Darwin 回调与输入源异步链统一跳主队列调度；其他线程直接调用属未定义行为。
//
//  时序约束：在途判定链由输入源代际机制作废（reset 递增代际）；
//  -handleReset 只清本机状态，1s 后按模式 resync 由 APSPlugin 调度（幂等）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* 输入源类型（同时作为触发模式枚举：None = 两开关都关） */
typedef NS_ENUM(NSInteger, APSInputSourceType) {
    APSInputSourceNone   = 0,   /* 无模式：不自动开关省电 */
    APSInputSourceScreen = 1,   /* 熄屏模式：屏幕灭 = 触发态 */
    APSInputSourceLock   = 2,   /* 锁屏模式：设备锁定 = 触发态 */
};

/* 触发态去抖记忆（tri-state：Unknown 支持"未初始化/首次同步必动作"语义） */
typedef NS_ENUM(NSInteger, APSInputActive) {
    APSInputActiveUnknown = -1,
    APSInputActiveNo      = 0,   /* 非触发态：屏幕亮 / 已解锁 */
    APSInputActiveYes     = 1,   /* 触发态：屏幕灭 / 已锁定 */
};

@interface APSStateMachine : NSObject

+ (instancetype)shared;

/* 配置解析：当前触发模式对应的输入源（互斥防呆：双开优先熄屏） */
+ (APSInputSourceType)currentModeSource;

/* 判定进行中标志。按输入源分开存储：屏幕判定不阻塞锁屏判定，反之亦然 */
- (BOOL)resolvePendingForSource:(APSInputSourceType)source;
- (void)setResolvePending:(BOOL)pending forSource:(APSInputSourceType)source;

/* 去抖记忆（触发态语义）。按输入源分开：非当前模式的输入源事件不会污染另一输入源记忆 */
- (APSInputActive)lastTriggerActiveForSource:(APSInputSourceType)source;

/* 输入源判定完成后的统一上报入口（去抖 → 模式匹配 → 统一决策） */
- (void)handleTriggerActive:(BOOL)active source:(APSInputSourceType)source;

/* 低电量模式被外部关闭（充电至 80% 系统自动关、用户手动关）：清理插件标志 */
- (void)handleExternalLowPowerOff;

/* 一键重置：清统一状态 + 插件标志，强制关闭低电量模式。
 * 注：调用前协调者（APSPlugin）已递增输入源代际作废在途判定链；
 * 1s 后的按模式 resync 也由协调者调度。 */
- (void)handleReset;

@end

NS_ASSUME_NONNULL_END
