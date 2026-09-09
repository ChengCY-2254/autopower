#import "APSStateMachine.h"
#import "APSLog.h"
#import "APSConfig.h"
#import "APSLowPowerProvider.h"
#import "APSScreenProvider.h"

#import <UIKit/UIKit.h>

#pragma mark - 决策核心

typedef NS_ENUM(NSInteger, APSDecisionAction) {
    APSDecisionActionNone = 0,
    APSDecisionActionEnableLowPower,   /* 开省电 + 标记插件开启 */
    APSDecisionActionDisableLowPower,  /* 关省电 + 清插件标记 */
    APSDecisionActionClearPluginFlag,  /* 仅清插件标记（省电已不在开） */
    APSDecisionActionKeepUser,         /* 保留用户开启的省电，不动 */
};

typedef NS_ENUM(NSInteger, APSDecisionReason) {
    APSDecisionReasonUnchanged,    /* 去抖：状态未翻转 */
    APSDecisionReasonDisabled,     /* 插件总开关关闭 */
    APSDecisionReasonModeMismatch, /* 非当前模式的输入源 */
    APSDecisionReasonAlreadyOn,    /* 省电已在开启状态 */
    APSDecisionReasonTriggered,    /* 触发态正常开省电 */
    APSDecisionReasonRestored,     /* 恢复态正常关省电 */
    APSDecisionReasonLowPowerOff,  /* 恢复时省电已关，清残留标记 */
    APSDecisionReasonUserKept,     /* 用户开的省电，保留 */
    APSDecisionReasonExternalOff,  /* 低电量被外部关闭，清残留标记 */
    APSDecisionReasonClean,        /* 无需清理 */
};

typedef struct {
    APSDecisionAction action;
    APSDecisionReason reason;
} APSDecision;

/* 决策函数只读取此快照，不访问外部依赖。 */
typedef struct {
    BOOL enabled;              /* APSConfig.enabled */
    BOOL ignoreUser;           /* APSConfig.ignoreUserLowPower */
    APSInputSourceType mode;   /* currentModeSource 解析结果 */
    BOOL lowPowerOn;           /* 低电量 provider 当前状态 */
    BOOL pluginFlagged;        /* APSConfig.pluginFlagged */
} APSContext;

typedef struct {
    APSInputActive screenLast;   /* 屏幕去抖记忆 */
    APSInputActive lockLast;     /* 锁屏去抖记忆 */
    BOOL screenPending;          /* 屏幕判定进行中 */
    BOOL lockPending;            /* 锁屏判定进行中 */
} APSState;

static APSState APSStateMakeInitial(void) {
    APSState s = {0};
    s.screenLast = APSInputActiveUnknown;   /* 未初始化：首次同步必动作 */
    s.lockLast = APSInputActiveUnknown;
    return s;
}

/* 重置后的状态：pending 清空，屏幕记忆按当前亮度粗同步（亮=非触发，灭=触发） */
static APSState APSStateMakeReset(BOOL brightnessOn) {
    APSState s = {0};
    s.screenLast = brightnessOn ? APSInputActiveNo : APSInputActiveYes;
    s.lockLast = APSInputActiveUnknown;
    return s;
}

/* 输入源上报触发态事件；决策与副作用分离。 */
static APSDecision APSDecideTriggerActive(APSState *state, APSContext ctx,
                                          BOOL active, APSInputSourceType source) {
    APSInputActive newState = active ? APSInputActiveYes : APSInputActiveNo;
    APSInputActive *last = (source == APSInputSourceLock) ? &state->lockLast : &state->screenLast;

    BOOL changed = (*last == APSInputActiveUnknown || newState != *last);
    *last = newState;

    if (!changed) return (APSDecision){APSDecisionActionNone, APSDecisionReasonUnchanged};
    if (!ctx.enabled) return (APSDecision){APSDecisionActionNone, APSDecisionReasonDisabled};
    if (source != ctx.mode) return (APSDecision){APSDecisionActionNone, APSDecisionReasonModeMismatch};

    if (active) {
        if (ctx.lowPowerOn) return (APSDecision){APSDecisionActionNone, APSDecisionReasonAlreadyOn};
        return (APSDecision){APSDecisionActionEnableLowPower, APSDecisionReasonTriggered};
    }

    if (!ctx.lowPowerOn) return (APSDecision){APSDecisionActionClearPluginFlag, APSDecisionReasonLowPowerOff};
    if (ctx.pluginFlagged || !ctx.ignoreUser) {
        return (APSDecision){APSDecisionActionDisableLowPower, APSDecisionReasonRestored};
    }
    return (APSDecision){APSDecisionActionKeepUser, APSDecisionReasonUserKept};
}

/* 外部关闭低电量时清理插件标记。 */
static APSDecision APSDecideExternalLowPowerOff(APSContext ctx) {
    if (!ctx.lowPowerOn && ctx.pluginFlagged) {
        return (APSDecision){APSDecisionActionClearPluginFlag, APSDecisionReasonExternalOff};
    }
    return (APSDecision){APSDecisionActionNone, APSDecisionReasonClean};
}

#pragma mark - 执行层

@implementation APSStateMachine {
    APSState _state;
}

+ (instancetype)shared {
    static APSStateMachine *machine = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ machine = [APSStateMachine new]; });
    return machine;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _state = APSStateMakeInitial();
    }
    return self;
}

#pragma mark - 状态存取

- (BOOL)resolvePendingForSource:(APSInputSourceType)source {
    return (source == APSInputSourceLock) ? _state.lockPending : _state.screenPending;
}

- (void)setResolvePending:(BOOL)pending forSource:(APSInputSourceType)source {
    if (source == APSInputSourceLock) {
        _state.lockPending = pending;
    } else {
        _state.screenPending = pending;
    }
}

- (APSInputActive)lastTriggerActiveForSource:(APSInputSourceType)source {
    return (source == APSInputSourceLock) ? _state.lockLast : _state.screenLast;
}

#pragma mark - 触发模式

+ (APSInputSourceType)currentModeSource {
    BOOL screenOffMode = [APSConfig screenOffModeEnabled];
    BOOL lockedMode    = [APSConfig lockedModeEnabled];
    if (screenOffMode && lockedMode) {
        /* 两个模式同时开启时保留配置，仅确定性地优先熄屏模式。 */
        APSLog(@"mode CONFLICT: ScreenOffMode+LockedMode both ON, prefer screenOff");
        return APSInputSourceScreen;
    }
    if (lockedMode) return APSInputSourceLock;
    if (screenOffMode) return APSInputSourceScreen;
    return APSInputSourceNone;
}

#pragma mark - 统一入口

- (NSString *)triggerNameForSource:(APSInputSourceType)source {
    return (source == APSInputSourceLock) ? @"locked" : @"screen off";
}

- (NSString *)restoreNameForSource:(APSInputSourceType)source {
    return (source == APSInputSourceLock) ? @"unlocked" : @"screen on";
}

- (APSContext)snapshotContext {
    APSContext ctx;
    ctx.enabled = [APSConfig enabled];
    ctx.ignoreUser = [APSConfig ignoreUserLowPower];
    ctx.mode = [APSStateMachine currentModeSource];
    ctx.lowPowerOn = [[APSLowPowerProviderRegistry current] isLowPowerOn];
    ctx.pluginFlagged = [APSConfig pluginFlagged];
    return ctx;
}

- (void)handleTriggerActive:(BOOL)active source:(APSInputSourceType)source {
    APSContext ctx = [self snapshotContext];
    APSDecision decision = APSDecideTriggerActive(&_state, ctx, active, source);
    [self applyDecision:decision ctx:ctx active:active source:source];
}

- (void)handleExternalLowPowerOff {
    APSContext ctx = [self snapshotContext];
    APSDecision decision = APSDecideExternalLowPowerOff(ctx);
    [self applyDecision:decision ctx:ctx active:NO source:APSInputSourceNone];
}

- (void)handleReset {
    APSLog(@"RESET: begin");
    [APSConfig setResetRequested:NO];

    _state = APSStateMakeReset([APSScreenProviderRegistry brightnessOn]);
    [APSConfig setPluginFlagged:NO];

    [[APSLowPowerProviderRegistry current] setLowPowerOn:NO];

    APSLog(@"RESET: low power OFF, lastScreenActive=%ld (brightness=%.3f)",
           (long)_state.screenLast, [UIScreen mainScreen].brightness);
    APSLog(@"RESET: done (1s resync scheduled by coordinator)");
}

#pragma mark - 执行决策

- (void)applyDecision:(APSDecision)d ctx:(APSContext)ctx
               active:(BOOL)active source:(APSInputSourceType)source {
    switch (d.action) {
        case APSDecisionActionEnableLowPower:
            [[APSLowPowerProviderRegistry current] setLowPowerOn:YES];
            [APSConfig setPluginFlagged:YES];
            break;
        case APSDecisionActionDisableLowPower:
            [[APSLowPowerProviderRegistry current] setLowPowerOn:NO];
            [APSConfig setPluginFlagged:NO];
            break;
        case APSDecisionActionClearPluginFlag:
            [APSConfig setPluginFlagged:NO];
            break;
        default:
            break;
    }

    switch (d.reason) {
        case APSDecisionReasonUnchanged:
            APSLog(@"input state unchanged (active=%d), no action", active);
            break;
        case APSDecisionReasonDisabled:
            APSLog(@"input changed but plugin disabled, observe only");
            break;
        case APSDecisionReasonModeMismatch:
            APSLog(@"input %@ but mode source != %ld, observe only",
                   active ? @"active" : @"inactive", (long)source);
            break;
        case APSDecisionReasonAlreadyOn:
            APSLog(@"%@, low power already on, skip", [self triggerNameForSource:source]);
            break;
        case APSDecisionReasonTriggered:
            APSLog(@"%@ -> low power ON (plugin)", [self triggerNameForSource:source]);
            break;
        case APSDecisionReasonRestored:
            APSLog(@"%@ -> low power OFF (pluginFlagged=%d ignoreUser=%d)",
                   [self restoreNameForSource:source], ctx.pluginFlagged, ctx.ignoreUser);
            break;
        case APSDecisionReasonLowPowerOff:
            APSLog(@"%@, low power off, cleared plugin flag", [self restoreNameForSource:source]);
            break;
        case APSDecisionReasonUserKept:
            APSLog(@"%@, low power kept (user-triggered)", [self restoreNameForSource:source]);
            break;
        case APSDecisionReasonExternalOff:
            APSLog(@"low power turned off externally, cleared plugin flag");
            break;
        case APSDecisionReasonClean:
            break;   /* 无需动作且无需日志 */
    }
}

@end
