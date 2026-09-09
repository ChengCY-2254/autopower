//
//  APSGuard.h
//  AutoPower
//
//  私有 API 安全调用的统一入口：所有 Provider 对私有对象（_PMLowPowerMode /
//  SBBacklightController / SBLockStateAggregator / SBLockScreenManager 等）的
//  读写必须经由本工具，禁止裸调——私有方法签名与运行时不符时会抛 ObjC 异常，
//  裸调将直接崩溃（插件注入 SpringBoard，崩溃即安全模式）。
//
//  统一语义：异常 → 记录日志（操作名 + 异常描述）→ 返回 fallback / 跳过执行
//  → *failed = YES。
//  provider 收到 failed=YES 后各自降级：屏幕/锁屏信源永久禁用并回退兜底
//  （亮度 / 另一信源）；低电量信源本次无效，下次调用重试（isAvailable 把关
//  类兼容性，读写异常属偶发）。
//  预检（respondsToSelector / isKindOfClass）仍是第一道防线，guard 是兜底。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

BOOL APSGuardCallBool(NSString *op, BOOL fallback, BOOL *_Nullable failed,
                      NS_NOESCAPE BOOL (^body)(void));
int64_t APSGuardCallInt64(NSString *op, int64_t fallback, BOOL *_Nullable failed,
                          NS_NOESCAPE int64_t (^body)(void));
void APSGuardCallVoid(NSString *op, BOOL *_Nullable failed,
                      NS_NOESCAPE void (^body)(void));

NS_ASSUME_NONNULL_END
