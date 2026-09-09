#import "APSGuard.h"
#import "APSLog.h"

BOOL APSGuardCallBool(NSString *op, BOOL fallback, BOOL *failed,
                      NS_NOESCAPE BOOL (^body)(void)) {
    @try {
        if (failed) *failed = NO;
        return body ? body() : fallback;
    } @catch (NSException *e) {
        if (failed) *failed = YES;
        APSLog(@"%@ exception: %@ (fallback=%d)", op, e, fallback);
        return fallback;
    }
}

int64_t APSGuardCallInt64(NSString *op, int64_t fallback, BOOL *failed,
                          NS_NOESCAPE int64_t (^body)(void)) {
    @try {
        if (failed) *failed = NO;
        return body ? body() : fallback;
    } @catch (NSException *e) {
        if (failed) *failed = YES;
        APSLog(@"%@ exception: %@ (fallback=%lld)", op, e, fallback);
        return fallback;
    }
}

void APSGuardCallVoid(NSString *op, BOOL *failed,
                      NS_NOESCAPE void (^body)(void)) {
    @try {
        if (failed) *failed = NO;
        if (body) body();
    } @catch (NSException *e) {
        if (failed) *failed = YES;
        APSLog(@"%@ exception: %@ (operation skipped)", op, e);
    }
}
