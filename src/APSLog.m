/* 日志文件轮转上限：超过后删除重建。 */
static const unsigned long long kLogMaxSizeBytes = 256 * 1024;

#import "APSLog.h"
#import "APSConfig.h"

void APSLog(NSString *fmt, ...) {
    if (![APSConfig prefForKey:APSLogEnabledKey defaultValue:NO]) return;

    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    NSLog(@"[AutoPower] %@", msg);

    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:APSLogPath error:NULL];
    if ([attrs[NSFileSize] longLongValue] > kLogMaxSizeBytes) {
        [fm removeItemAtPath:APSLogPath error:NULL];
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:APSLogPath];
    if (!fh) {
        [fm createFileAtPath:APSLogPath contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:APSLogPath];
    }
    if (fh) {
        @try {
            [fh seekToEndOfFile];
            NSDateFormatter *df = [[NSDateFormatter alloc] init];
            df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
            NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                              [df stringFromDate:[NSDate date]], msg];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        } @catch (NSException *e) {
        } @finally {
            [fh closeFile];
        }
    }
}
