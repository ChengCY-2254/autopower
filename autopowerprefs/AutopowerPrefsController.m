#import <UIKit/UIKit.h>
#import <dlfcn.h>

static NSString *const kPrefsSuite = @"io.cheng.autopower";
static NSString *const kResetRequestKey = @"ResetRequested";
static NSString *const kResetNotifName = @"io.cheng.autopower.reset";
#ifndef APSLOG_DISABLED
static NSString *const kLogPath = @"/var/mobile/Library/Preferences/autopower.log";
static NSString *const kLogEnabledKey = @"LogEnabled";
#endif

#ifndef APSLOG_DISABLED
static void prefsLog(NSString *fmt, ...) {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kPrefsSuite];
    if (![d boolForKey:kLogEnabledKey]) return;

    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);

    NSFileManager *fm = [NSFileManager defaultManager];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
    if (!fh) {
        [fm createFileAtPath:kLogPath contents:nil attributes:nil];
        fh = [NSFileHandle fileHandleForWritingAtPath:kLogPath];
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
#else
#define prefsLog(...) do {} while (0)
#endif


// 中文和英文作为首选语言
static NSString *APSResolveLocalization(NSString *pref) {
    if (pref.length == 0) return @"en";
    /* 简体中文：zh-Hans*（含 zh-Hans-CN）、zh-CN*、zh_CN*；
     * 繁体（zh-Hant / zh-TW / zh-HK）及其它语言回退英文。 */
    if ([pref hasPrefix:@"zh-Hans"] || [pref hasPrefix:@"zh-CN"]
        || [pref hasPrefix:@"zh_CN"]) {
        return @"zh-Hans";
    }
    return @"en";
}

/* 系统首选语言：以 Settings 主 bundle 为准。 */
static NSString *APSSelectedLocalization(void) {
    return APSResolveLocalization([[NSBundle mainBundle] preferredLocalizations].firstObject);
}

/* 显式查表：读取选定 lproj 的 Localizable.strings（中文 -> zh-Hans，
 * 英文及其它语言 -> en）；查不到翻译时回退 key 本身。 */
static NSString *APSStringFromTable(NSString *key, NSBundle *bundle) {
    if (key.length == 0) return key;
    NSString *loc = APSSelectedLocalization();
    NSString *lprojPath = loc ? [bundle pathForResource:loc ofType:@"lproj"] : nil;
    if (lprojPath) {
        NSBundle *lprojBundle = [NSBundle bundleWithPath:lprojPath];
        NSString *translated = [lprojBundle localizedStringForKey:key value:key table:nil];
        if (translated && ![translated isEqualToString:key]) {
            return translated;
        }
    }
    return key;
}

@class PSSpecifier;

/* Preferences 私有框架由设备提供，接口通过 dynamic_lookup 解析。
 * cell 渲染读的是 name；label/footerText 作为 property 由加载器写入。 */
@interface PSListController : UIViewController
- (id)specifiers;
- (PSSpecifier *)specifierAtIndexPath:(NSIndexPath *)indexPath;
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath;
- (void)reloadSpecifier:(PSSpecifier *)specifier animated:(BOOL)animated;
@end

/* iOS 18.6 无 action 属性，点击由 didSelect 覆写处理。 */
@interface PSSpecifier : NSObject
+ (instancetype)preferenceSpecifierNamed:(NSString *)name target:(id)target
                                     set:(SEL)set get:(SEL)get
                                  detail:(Class)detail cell:(NSString *)cell
                                    edit:(Class)edit;
+ (instancetype)groupSpecifierWithName:(NSString *)name;
+ (instancetype)emptyGroupSpecifier;
- (NSString *)name;
- (void)setName:(NSString *)name;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (void)setTarget:(id)target;
- (id)propertyForKey:(NSString *)key;
- (void)setIdentifier:(NSString *)identifier;
@end

@interface autopowerprefs : PSListController
@property (nonatomic, strong) NSArray *cachedSpecifiers;
- (NSArray *)buildSpecifiersFromItems:(NSArray *)items;
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
#ifndef APSLOG_DISABLED
- (void)showLog:(id)specifier;
#endif
- (void)resetState:(id)specifier;
- (void)refreshSpecifierForKey:(NSString *)key;
- (NSString *)localizedStringForKey:(NSString *)key;
- (NSArray *)relocalizeSpecifiers:(NSArray *)specs;
@end

#ifndef APSLOG_DISABLED
@interface AutopowerLogViewController : UIViewController
@end
#endif

@implementation autopowerprefs

+ (void)initialize {
    if (self == [autopowerprefs class]) {
        prefsLog(@"[AutoPower] prefs controller class initialized, bundle=%@",
                 [NSBundle bundleForClass:self].bundlePath);
    }
}

- (id)specifiers {
    // PreferenceLoader 生成的 specifier 渲染最完整。
    @try {
        NSArray *loaderSpecs = [super specifiers];
        if (loaderSpecs && loaderSpecs.count > 0) {
            prefsLog(@"[AutoPower] prefs: using PreferenceLoader items (%lu specifiers)",
                     (unsigned long)loaderSpecs.count);
            loaderSpecs = [self stripLogSpecifiers:loaderSpecs];
            loaderSpecs = [self relocalizeSpecifiers:loaderSpecs];
            @try {
                [self setValue:loaderSpecs forKey:@"_specifiers"];
            } @catch (NSException *e) {
                prefsLog(@"[AutoPower] prefs: KVC set _specifiers failed: %@", e);
            }
            return loaderSpecs;
        }
        prefsLog(@"[AutoPower] prefs: PreferenceLoader items empty, falling back to manual build");
    } @catch (NSException *e) {
        prefsLog(@"[AutoPower] prefs: super specifiers failed: %@, falling back to manual build", e);
    }

    // 直接读 plist，避免 Preferences 进程中的私有路径查找。
    if (self.cachedSpecifiers == nil) {
        NSBundle *bundle = [NSBundle bundleForClass:[self class]];
        prefsLog(@"[AutoPower] prefs: building specifiers manually, bundle=%@", bundle.bundlePath);

        NSString *plistPath = nil;
        for (NSString *candidate in @[
                 [bundle.bundlePath stringByAppendingPathComponent:@"AutopowerSettings.plist"],
                 [[bundle.bundlePath stringByAppendingPathComponent:@"Resources"]
                     stringByAppendingPathComponent:@"AutopowerSettings.plist"]]) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
                plistPath = candidate;
                break;
            }
        }
        if (plistPath) {
            self.cachedSpecifiers = [self buildSpecifiersViaLibprefs:plistPath];
            if (self.cachedSpecifiers == nil) {
                NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
                self.cachedSpecifiers = [self buildSpecifiersFromItems:plist[@"items"]] ?: @[];
                prefsLog(@"[AutoPower] prefs: manual built %lu specifiers",
                         (unsigned long)self.cachedSpecifiers.count);
            }
        } else {
            prefsLog(@"[AutoPower] prefs: ERROR no AutopowerSettings.plist in bundle");
            self.cachedSpecifiers = @[];
        }
    }

    // tableView 数据源读取 _specifiers ivar，系统可能重置它。
    self.cachedSpecifiers = [self stripLogSpecifiers:self.cachedSpecifiers];
    self.cachedSpecifiers = [self relocalizeSpecifiers:self.cachedSpecifiers];
    @try {
        [self setValue:self.cachedSpecifiers forKey:@"_specifiers"];
    } @catch (NSException *e) {
        prefsLog(@"[AutoPower] prefs: KVC set _specifiers failed: %@", e);
    }
    return self.cachedSpecifiers;
}

/* release 构建（APSLOG_DISABLED）：剔除日志相关设置项（LogEnabled 开关、
 * 「查看运行日志」链接、日志说明分组）；保留「重置插件状态」等功能项。
 * debug 构建：原样返回，零开销。 */
- (NSArray *)stripLogSpecifiers:(NSArray *)specs {
#ifndef APSLOG_DISABLED
    return specs;
#else
    if (specs.count == 0) return specs;
    NSMutableArray *kept = [NSMutableArray array];
    for (PSSpecifier *s in specs) {
        NSString *cell = [s propertyForKey:@"cell"];
        NSString *key = [s propertyForKey:@"key"];
        NSString *action = [s propertyForKey:@"action"];
        NSString *footer = [s propertyForKey:@"footerText"];
        if ([key isEqualToString:@"LogEnabled"]) continue;
        if ([action isEqualToString:@"showLog:"]) continue;
        /* 日志说明分组：footerText 在本地化前是 plist 中的 key
         * （diagnostics.logFooter），本地化后是含日志路径的文本；
         * 两种形态都判为依据。 */
        if ([cell isEqualToString:@"PSGroupCell"] && footer
            && ([footer isEqualToString:@"diagnostics.logFooter"]
                || [footer containsString:@"autopower.log"])) continue;
        [kept addObject:s];
    }
    return kept;
#endif
}

/* 用 libprefs.dylib 的 SpecifiersFromPlist（PreferenceLoader 官方构造器）生成 specifiers。
 * 返回 nil 表示 libprefs 不可用或构造失败，调用方应回退手动构造。 */
- (NSArray *)buildSpecifiersViaLibprefs:(NSString *)plistPath {
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    if (!plist) return nil;

    void *handle = dlopen("/usr/lib/libprefs.dylib", RTLD_LAZY);
    if (!handle) handle = dlopen("/var/jb/usr/lib/libprefs.dylib", RTLD_LAZY);
    if (!handle) {
        prefsLog(@"[AutoPower] prefs: libprefs.dylib not found");
        return nil;
    }
    typedef NSArray *(*SpecifiersFromPlistFn)(NSDictionary *, PSSpecifier *, id,
                                              NSString *, NSBundle *, NSString *,
                                              NSString *, PSListController *, NSMutableArray **);
    SpecifiersFromPlistFn fn = (SpecifiersFromPlistFn)dlsym(handle, "SpecifiersFromPlist");
    if (!fn) {
        prefsLog(@"[AutoPower] prefs: SpecifiersFromPlist symbol not found");
        return nil;
    }
    NSMutableArray *bundleControllers = [NSMutableArray array];
    NSArray *specs = fn(plist, nil, self, @"AutopowerSettings",
                        [NSBundle bundleForClass:[self class]],
                        nil, nil, self, &bundleControllers);
    prefsLog(@"[AutoPower] prefs: libprefs built %lu specifiers",
             (unsigned long)(specs ? specs.count : 0));
    return specs;
}

/* 本地化查表（见文件顶部 APSStringFromTable）：绕开 libprefs 的隐式
 * CFBundle 语言匹配，保证手动构造路径与 PreferenceLoader 路径显示一致。 */
- (NSString *)localizedStringForKey:(NSString *)key {
    return APSStringFromTable(key, [NSBundle bundleForClass:[self class]]);
}

/* 幂等重本地化：cell 渲染读 PSSpecifier 的 name（framework 与 libprefs
 * 两条加载路径都可能留下未翻译的英文 name），因此同时改写 name 与
 * label property。已翻译文本（不在表 key 中）原样保留。 */
- (NSArray *)relocalizeSpecifiers:(NSArray *)specs {
    if (specs.count == 0) return specs;
    for (PSSpecifier *s in specs) {
        NSString *label = [s propertyForKey:@"label"] ?: [s name];
        if (label.length) {
            NSString *translated = [self localizedStringForKey:label];
            [s setProperty:translated forKey:@"label"];
            [s setName:translated];
        }
        NSString *footer = [s propertyForKey:@"footerText"];
        if (footer.length) {
            [s setProperty:[self localizedStringForKey:footer] forKey:@"footerText"];
        }
    }
    return specs;
}

/* 手动构造 specifier（不经 libprefs，作为其不可用时的回退路径）：
 * 表项按 cell 类型分别构造分组 / 开关 / 链接。 */
- (NSArray *)buildSpecifiersFromItems:(NSArray *)items {
    NSMutableArray *specs = [NSMutableArray array];
    for (NSDictionary *item in items) {
        @try {
            PSSpecifier *spec = nil;
            NSString *cell = item[@"cell"];
            NSString *label = [self localizedStringForKey:item[@"label"]];
            if ([cell isEqualToString:@"PSGroupCell"]) {
                spec = label
                    ? [PSSpecifier groupSpecifierWithName:label]
                    : [PSSpecifier emptyGroupSpecifier];
                if (label) [spec setProperty:label forKey:@"label"];
                if (item[@"footerText"]) {
                    [spec setProperty:[self localizedStringForKey:item[@"footerText"]]
                              forKey:@"footerText"];
                }
            } else if ([cell isEqualToString:@"PSSwitchCell"]) {
                spec = [PSSpecifier preferenceSpecifierNamed:label target:self
                            set:@selector(setPreferenceValue:specifier:)
                            get:@selector(readPreferenceValue:)
                            detail:nil cell:cell edit:nil];
                [spec setTarget:self];
                for (NSString *key in @[@"defaults", @"key", @"default", @"label"]) {
                    if (item[key]) {
                        [spec setProperty:([key isEqualToString:@"label"] ? label : item[key])
                                  forKey:key];
                    }
                }
            } else {
                spec = [PSSpecifier preferenceSpecifierNamed:label target:self
                            set:NULL get:NULL detail:nil cell:cell edit:nil];
                [spec setTarget:self];
                for (NSString *key in @[@"defaults", @"key", @"default", @"label",
                                        @"isController", @"bundle"]) {
                    if (item[key]) {
                        [spec setProperty:([key isEqualToString:@"label"] ? label : item[key])
                                  forKey:key];
                    }
                }
                if (item[@"action"]) {
                    if ([item[@"action"] isEqualToString:@"showLog:"]) {
                        [spec setProperty:@YES forKey:@"autopowerLogEntry"];
                    } else if ([item[@"action"] isEqualToString:@"resetState:"]) {
                        [spec setProperty:@YES forKey:@"autopowerResetEntry"];
                    }
                }
            }
            if (spec) {
                NSString *identifier = item[@"key"] ?: item[@"label"];
                if (identifier) [spec setIdentifier:identifier];
                [specs addObject:spec];
            }
        } @catch (NSException *e) {
            prefsLog(@"[AutoPower] prefs: specifier build failed: %@", e);
        }
    }
    return specs;
}

/* 覆写点击：日志入口（autopowerLogEntry 标记）直接进入日志页，
 * 重置入口（autopowerResetEntry 标记）执行一键重置，其余交还 super。
 * 双保险识别：自定义标记 property 或 action 字符串（兼容 libprefs 路径）。 */
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    @try {
        PSSpecifier *spec = [self specifierAtIndexPath:indexPath];
        NSString *action = [spec propertyForKey:@"action"];
#ifndef APSLOG_DISABLED
        BOOL logEntry = [[spec propertyForKey:@"autopowerLogEntry"] boolValue]
                        || [action isEqualToString:@"showLog:"];
#endif
        BOOL resetEntry = [[spec propertyForKey:@"autopowerResetEntry"] boolValue]
                          || [action isEqualToString:@"resetState:"];
#ifndef APSLOG_DISABLED
        if (logEntry) {
            [self showLog:spec];
            [tableView deselectRowAtIndexPath:indexPath animated:YES];
            return;
        }
#endif
        if (resetEntry) {
            [self resetState:spec];
            [tableView deselectRowAtIndexPath:indexPath animated:YES];
            return;
        }
    } @catch (NSException *e) {
        prefsLog(@"[AutoPower] prefs: didSelect lookup failed: %@", e);
    }
    [super tableView:tableView didSelectRowAtIndexPath:indexPath];
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *defaults = [specifier propertyForKey:@"defaults"];
    NSString *key = [specifier propertyForKey:@"key"];
    prefsLog(@"[AutoPower] prefs: readPreferenceValue defaults=%@ key=%@", defaults, key);
    if (defaults && key) {
        NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:defaults];
        id value = [d objectForKey:key];
        if (value) {
            prefsLog(@"[AutoPower] prefs: read stored -> %@", value);
            return value;
        }
        id def = [specifier propertyForKey:@"default"];
        prefsLog(@"[AutoPower] prefs: read default -> %@", def);
        return def ?: @NO;
    }
    return @NO;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *defaults = [specifier propertyForKey:@"defaults"];
    NSString *key = [specifier propertyForKey:@"key"];
    prefsLog(@"[AutoPower] prefs: setPreferenceValue %@ defaults=%@ key=%@", value, defaults, key);
    if (defaults && key) {
        NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:defaults];
        [d setObject:value forKey:key];

        /* 触发模式互斥联动（开一个自动关另一个）。只写 NSUserDefaults 不刷新
         * cell 的话，另一个开关的显示要重进页面才更新。 */
        BOOL on = [value boolValue];
        if ([key isEqualToString:@"ScreenOffMode"] && on) {
            [d setBool:NO forKey:@"LockedMode"];
            prefsLog(@"[AutoPower] prefs: mutual exclusion, LockedMode -> NO");
            [self refreshSpecifierForKey:@"LockedMode"];
        } else if ([key isEqualToString:@"LockedMode"] && on) {
            [d setBool:NO forKey:@"ScreenOffMode"];
            prefsLog(@"[AutoPower] prefs: mutual exclusion, ScreenOffMode -> NO");
            [self refreshSpecifierForKey:@"ScreenOffMode"];
        }
        [d synchronize];
    }
}

/* 刷新指定 key 的 specifier 显示（互斥联动后另一开关立即更新为关） */
- (void)refreshSpecifierForKey:(NSString *)key {
    @try {
        for (PSSpecifier *s in self.specifiers) {
            if ([[s propertyForKey:@"key"] isEqualToString:key]) {
                [self reloadSpecifier:s animated:YES];
                prefsLog(@"[AutoPower] prefs: reloaded specifier %@", key);
                return;
            }
        }
        prefsLog(@"[AutoPower] prefs: specifier %@ not found for refresh", key);
    } @catch (NSException *e) {
        prefsLog(@"[AutoPower] prefs: refreshSpecifier failed: %@", e);
    }
}

/* 一键重置：写重置标记（防通知丢失）+ 发 Darwin 通知给 SpringBoard 插件。
 * 插件侧：清内部状态 + 关闭低电量模式 + 延迟 1s 重新同步；不删除日志。 */
- (void)resetState:(id)specifier {
    prefsLog(@"[AutoPower] prefs: reset requested");
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kPrefsSuite];
    [d setBool:YES forKey:kResetRequestKey];
    [d synchronize];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)kResetNotifName, NULL, NULL, true);
    prefsLog(@"[AutoPower] prefs: reset flag written + Darwin notification posted");
}

#ifndef APSLOG_DISABLED
- (void)showLog:(id)specifier {
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
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    self.title = APSStringFromTable(@"log.title", bundle);
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
        initWithTitle:APSStringFromTable(@"log.clear", bundle)
        style:UIBarButtonItemStylePlain target:self action:@selector(clearLog)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadLog];
}

- (void)reloadLog {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:kPrefsSuite];
    NSBundle *bundle = [NSBundle bundleForClass:[self class]];
    if (![d boolForKey:kLogEnabledKey]) {
        _textView.text = APSStringFromTable(@"log.disabledHint", bundle);
        return;
    }
    NSString *log = [NSString stringWithContentsOfFile:kLogPath encoding:NSUTF8StringEncoding error:NULL];
    _textView.text = (log.length > 0) ? log : APSStringFromTable(@"log.empty", bundle);
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
