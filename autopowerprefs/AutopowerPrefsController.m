/**
 * AutopowerPrefsController.m
 *
 * 设置页控制器。specifier 由 AutopowerSettings.plist 驱动，本类只负责：
 *   - 把分组里的日志相关项在 release 构建下隐藏
 *   - 开关的读写与触发模式互斥
 *   - 「查看日志」「重置插件状态」两个按钮的动作
 *
 * 本地化依赖 bundle 内的 zh-Hans.lproj / en.lproj，由 libprefs 按系统语言
 * 自动选择。
 */

#import <UIKit/UIKit.h>

#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

static NSString *const kPrefsSuite = @"io.cheng.autopower";
static NSString *const kResetRequestKey = @"ResetRequested";
static NSString *const kResetNotifName = @"io.cheng.autopower.reset";
#ifndef APSLOG_DISABLED
static NSString *const kLogPath = @"/var/mobile/Library/Preferences/autopower.log";
static NSString *const kLogEnabledKey = @"LogEnabled";
#endif

@interface AutopowerPrefsController : PSListController
@end

/* 用本 bundle 的 lproj 查表；缺翻译时回退 key 本身。 */
static NSString *APSLocalized(NSString *key) {
    if (key.length == 0) return key;
    return [[NSBundle bundleForClass:[AutopowerPrefsController class]]
               localizedStringForKey:key value:key table:nil];
}

#ifndef APSLOG_DISABLED
@interface AutopowerLogViewController : UIViewController
@end
#endif

@implementation AutopowerPrefsController

/* libprefs 经此读取设置 plist 与 lproj；子类必须自己给出 bundle。 */
- (NSBundle *)bundle {
    NSBundle *b = [NSBundle bundleForClass:[self class]];
    return b ?: [super bundle];
}

/* specifier 由 AutopowerSettings.plist 经 libprefs 构造并缓存在 _specifiers。
 * plist 中的文案是本地化 key，加载后逐项翻译；
 * release 构建不含日志功能，对应项在首次加载后移除一次。 */
- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"AutopowerSettings"
                                                 target:self
                                                 bundle:[self bundle]];
#ifdef APSLOG_DISABLED
        /* 移除日志项要在翻译前按 label 的 key 做，避免依赖具体语言的文本。 */
        NSString *logEnabledLabel = @"diagnostics.logEnabled";
        NSString *viewLogLabel = @"diagnostics.viewLog";
        NSString *logFooter = @"diagnostics.logFooter";
        NSUInteger i = 0;
        while (i < _specifiers.count) {
            PSSpecifier *s = _specifiers[i];
            NSString *name = s.name;
            BOOL isLogItem =
                [name isEqualToString:logEnabledLabel] ||
                [name isEqualToString:viewLogLabel] ||
                [[s propertyForKey:@"label"] isEqualToString:logEnabledLabel] ||
                [[s propertyForKey:@"label"] isEqualToString:viewLogLabel] ||
                [[s propertyForKey:@"footerText"] isEqualToString:logFooter];
            if (isLogItem) {
                [_specifiers removeObjectAtIndex:i];
            } else {
                i++;
            }
        }
#endif
        for (PSSpecifier *s in _specifiers) {
            NSString *name = s.name;
            if (name.length) [s setName:APSLocalized(name)];

            for (NSString *k in @[@"label", @"footerText", @"headerDetailText", @"placeholder"]) {
                NSString *v = [s propertyForKey:k];
                if (v.length) [s setProperty:APSLocalized(v) forKey:k];
            }
        }
    }
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *defaults = [specifier propertyForKey:@"defaults"];
    NSString *key = [specifier propertyForKey:@"key"];
    if (defaults && key) {
        NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:defaults];
        id value = [d objectForKey:key];
        if (value) return value;
        return [specifier propertyForKey:@"default"];
    }
    return @NO;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *defaults = [specifier propertyForKey:@"defaults"];
    NSString *key = [specifier propertyForKey:@"key"];
    if (!defaults || !key) return;

    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:defaults];
    [d setObject:value forKey:key];

    /* 触发模式二选一：开启一个即关闭另一个，并立即刷新被联动的行。 */
    if ([value boolValue]) {
        NSString *sibling = nil;
        if ([key isEqualToString:@"ScreenOffMode"]) sibling = @"LockedMode";
        else if ([key isEqualToString:@"LockedMode"]) sibling = @"ScreenOffMode";

        if (sibling) {
            [d setBool:NO forKey:sibling];
            for (PSSpecifier *s in self.specifiers) {
                if ([[s propertyForKey:@"key"] isEqualToString:sibling]) {
                    [self reloadSpecifier:s animated:YES];
                    break;
                }
            }
        }
    }
    [d synchronize];
}

/* 写重置标记并发 Darwin 通知；插件侧清状态、关低电量并重新同步。 */
- (void)resetState:(PSSpecifier *)specifier {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kPrefsSuite];
    [d setBool:YES forKey:kResetRequestKey];
    [d synchronize];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kResetNotifName, NULL, NULL, true);
}

#ifndef APSLOG_DISABLED
- (void)showLog:(PSSpecifier *)specifier {
    AutopowerLogViewController *vc = [[AutopowerLogViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}
#endif

@end

#ifndef APSLOG_DISABLED
@implementation AutopowerLogViewController {
    UITextView *_textView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = APSLocalized(@"log.title");
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    _textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    _textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _textView.editable = NO;
    _textView.selectable = YES;
    _textView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    _textView.textColor = [UIColor labelColor];
    _textView.contentInset = UIEdgeInsetsMake(8, 8, 8, 8);
    [self.view addSubview:_textView];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:APSLocalized(@"log.clear")
        style:UIBarButtonItemStylePlain target:self action:@selector(clearLog)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadLog];
}

- (void)reloadLog {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kPrefsSuite];
    if (![d boolForKey:kLogEnabledKey]) {
        _textView.text = APSLocalized(@"log.disabledHint");
        return;
    }
    NSString *log = [NSString stringWithContentsOfFile:kLogPath encoding:NSUTF8StringEncoding error:NULL];
    _textView.text = (log.length > 0) ? log : APSLocalized(@"log.empty");
    if (_textView.text.length > 0) {
        [_textView scrollRangeToVisible:NSMakeRange(_textView.text.length - 1, 1)];
    }
}

- (void)clearLog {
    [[NSFileManager defaultManager] removeItemAtPath:kLogPath error:NULL];
    [self reloadLog];
}

@end
#endif
