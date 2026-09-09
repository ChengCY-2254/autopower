//
//  APSLog.h
//  AutoPower
//
//  日志层：受 LogEnabled 配置控制，NSLog + 追加写文件（256KB 轮转）。
//  供框架各层复用的日志工具。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef APSLOG_DISABLED
/* release 构建（Makefile 在 FINALPACKAGE=1 时定义此宏）：
 * 日志系统不编译进二进制，所有调用点展开为空语句。
 * 注意：参数表达式会被丢弃，不要在日志参数里写有副作用的表达式。 */
#define APSLog(...) do {} while (0)
#else
FOUNDATION_EXPORT void APSLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
#endif

NS_ASSUME_NONNULL_END
