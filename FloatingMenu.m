#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#pragma mark - 日志窗口

static NSString * const kACBetNames[6] = {@"虎", @"芦", @"狮", @"蟹", @"鱼", @"虾"};

static double ACNumberValue(id v) {
    if ([v isKindOfClass:[NSNumber class]]) return [v doubleValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v doubleValue];
    return 0;
}

static id ACFindDeep(id obj, NSString *key, int depth) {
    if (!obj || depth > 8) return nil;
    if ([obj isKindOfClass:[NSDictionary class]]) {
        id v = ((NSDictionary *)obj)[key];
        if (v && ![v isKindOfClass:[NSNull class]]) return v;
        for (id k in (NSDictionary *)obj) {
            id r = ACFindDeep(((NSDictionary *)obj)[k], key, depth + 1);
            if (r) return r;
        }
    } else if ([obj isKindOfClass:[NSArray class]]) {
        for (id v in (NSArray *)obj) {
            id r = ACFindDeep(v, key, depth + 1);
            if (r) return r;
        }
    }
    return nil;
}

static NSDictionary *ACJSONObjectFromString(NSString *str) {
    NSString *trim = [str stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trim.length < 2) return nil;
    unichar c = [trim characterAtIndex:0];
    if (c != '{' && c != '[') return nil;
    NSData *data = [trim dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

static NSArray<NSNumber *> *ACBetTotalsFromJSON(NSDictionary *json) {
    id bet = ACFindDeep(json, @"bet", 0);
    if (![bet isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *betDict = bet;
    double totals[6] = {0};

    // 优先取 bet["1"] 这类完整六门快照，避免把多个外层分组重复累加
    id primary = betDict[@"1"];
    if ([primary isKindOfClass:[NSDictionary class]]) {
        BOOL complete = YES;
        for (int i = 1; i <= 6; i++) {
            id v = ((NSDictionary *)primary)[[NSString stringWithFormat:@"%d", i]];
            if (!v) { complete = NO; break; }
            totals[i - 1] = ACNumberValue(v);
        }
        if (complete) {
            NSMutableArray<NSNumber *> *arr = [NSMutableArray arrayWithCapacity:6];
            for (int i = 0; i < 6; i++) [arr addObject:@(totals[i])];
            return arr;
        }
    }
    memset(totals, 0, sizeof(totals));

    BOOL nested = NO;
    for (id v in betDict.allValues) {
        if ([v isKindOfClass:[NSDictionary class]]) { nested = YES; break; }
    }
    if (nested) {
        for (id sub in betDict.allValues) {
            if (![sub isKindOfClass:[NSDictionary class]]) continue;
            for (NSString *k in (NSDictionary *)sub) {
                NSInteger idx = k.integerValue;
                if (idx >= 1 && idx <= 6) totals[idx - 1] += ACNumberValue(((NSDictionary *)sub)[k]);
            }
        }
    } else {
        for (NSString *k in betDict) {
            NSInteger idx = k.integerValue;
            if (idx >= 1 && idx <= 6) totals[idx - 1] += ACNumberValue(betDict[k]);
        }
    }
    NSMutableArray<NSNumber *> *arr = [NSMutableArray arrayWithCapacity:6];
    for (int i = 0; i < 6; i++) [arr addObject:@(totals[i])];
    return arr;
}

static NSString *ACDiceName(NSInteger v) {
    if (v >= 1 && v <= 6) return kACBetNames[v - 1];
    return v > 0 ? [NSString stringWithFormat:@"%ld", (long)v] : @"?";
}

static NSString *ACCsvField(NSString *value) {
    if (![value isKindOfClass:[NSString class]]) return @"";
    if ([value containsString:@","] || [value containsString:@"\""] || [value containsString:@"\n"]) {
        NSString *escaped = [value stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""];
        return [NSString stringWithFormat:@"\"%@\"", escaped];
    }
    return value;
}

@interface DebugFloatWindow : NSObject <UITableViewDelegate, UITableViewDataSource, UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIWindow *floatWindow;
@property (nonatomic, strong) UIButton *floatBtn;
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UITableView *logTableView;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *logDataSource;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *roundRecords;
@property (nonatomic, strong) UILabel *summaryLabel;
@property (nonatomic, strong) UILabel *resultLabel;
@property (nonatomic, strong) UILabel *statsLabel;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *statsDict;
@property (nonatomic, strong) NSArray<NSNumber *> *currentBets;
+ (instancetype)sharedInstance;
- (void)addLog:(NSString *)title detail:(NSString *)detail;
- (void)ingestWSMessage:(NSString *)str direction:(NSString *)direction;
- (void)loadRecords;
- (void)saveRecords;
- (void)refreshSummaryLabels;
- (void)refreshStatsLabel;
- (void)exportCSV;
- (void)presentShareForFile:(NSString *)path sourceRect:(CGRect)rect;
- (NSString *)recordsDirectory;
- (NSString *)timestampString;
- (BOOL)handleJSONMessage:(NSDictionary *)json;
- (void)recordStepJSON:(NSDictionary *)json lottery:(NSArray *)lottery;
@end

@implementation DebugFloatWindow

+ (instancetype)sharedInstance {
    static DebugFloatWindow *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DebugFloatWindow alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        self.currentBets = @[@0, @0, @0, @0, @0, @0];
        self.statsDict = [@{
            @"虎": @0, @"芦": @0, @"狮": @0, @"蟹": @0, @"鱼": @0, @"虾": @0
        } mutableCopy];
        [self loadRecords];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(setupUI)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self setupUI];
        });
    }
    return self;
}

- (NSMutableArray<NSDictionary *> *)logDataSource {
    if (!_logDataSource) {
        _logDataSource = [NSMutableArray array];
    }
    return _logDataSource;
}

- (NSMutableArray<NSDictionary *> *)roundRecords {
    if (!_roundRecords) {
        _roundRecords = [NSMutableArray array];
    }
    return _roundRecords;
}

- (UIWindow *)getKeyWindow {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) return w;
            }
            if (ws.windows.count > 0) return ws.windows.firstObject;
        }
    }
    return UIApplication.sharedApplication.windows.firstObject;
}

- (void)setupUI {
    if (self.floatWindow) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        static BOOL sSetupDone = NO;
        if (sSetupDone) return;
        UIWindow *keyWindow = [self getKeyWindow];
        if (!keyWindow) return;
        sSetupDone = YES;

        if (@available(iOS 13.0, *)) {
            if (keyWindow.windowScene) {
                self.floatWindow = [[UIWindow alloc] initWithWindowScene:keyWindow.windowScene];
            }
        }
        if (!self.floatWindow) {
            self.floatWindow = [[UIWindow alloc] initWithFrame:CGRectMake(20, 100, 46, 46)];
        }
        self.floatWindow.frame = CGRectMake(20, 100, 46, 46);
        self.floatWindow.windowLevel = UIWindowLevelAlert + 1000;
        self.floatWindow.backgroundColor = [UIColor clearColor];
        UIViewController *hostVC = [[UIViewController alloc] init];
        hostVC.view.backgroundColor = [UIColor clearColor];
        self.floatWindow.rootViewController = hostVC;
        self.floatWindow.hidden = NO;

        self.floatBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        self.floatBtn.frame = self.floatWindow.bounds;
        self.floatBtn.backgroundColor = [[UIColor systemBlueColor] colorWithAlphaComponent:0.85];
        self.floatBtn.layer.cornerRadius = 23;
        [self.floatBtn setTitle:@"日志" forState:UIControlStateNormal];
        self.floatBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        [self.floatBtn addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
        [self.floatBtn addGestureRecognizer:pan];
        [hostVC.view addSubview:self.floatBtn];

        CGFloat panelW = MIN(keyWindow.bounds.size.width - 40, 420);
        CGFloat panelH = MIN(keyWindow.bounds.size.height - 80, 280);
        self.panelView = [[UIView alloc] initWithFrame:CGRectMake(20, 60, panelW, panelH)];
        self.panelView.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.88];
        self.panelView.layer.cornerRadius = 10;
        self.panelView.hidden = YES;
        UIPanGestureRecognizer *panelPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanelPan:)];
        panelPan.delegate = self;
        [self.panelView addGestureRecognizer:panelPan];

        UIButton *exportBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        exportBtn.frame = CGRectMake(10, 5, 80, 30);
        [exportBtn setTitle:@"导出日志" forState:UIControlStateNormal];
        [exportBtn setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
        exportBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        [exportBtn addTarget:self action:@selector(exportLogs) forControlEvents:UIControlEventTouchUpInside];
        [self.panelView addSubview:exportBtn];

        UIButton *csvBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        csvBtn.frame = CGRectMake(94, 5, 60, 30);
        [csvBtn setTitle:@"CSV" forState:UIControlStateNormal];
        [csvBtn setTitleColor:[UIColor systemCyanColor] forState:UIControlStateNormal];
        csvBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        [csvBtn addTarget:self action:@selector(exportCSV) forControlEvents:UIControlEventTouchUpInside];
        [self.panelView addSubview:csvBtn];

        UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        clearBtn.frame = CGRectMake(158, 5, 50, 30);
        [clearBtn setTitle:@"清空" forState:UIControlStateNormal];
        [clearBtn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
        clearBtn.titleLabel.font = [UIFont systemFontOfSize:12];
        [clearBtn addTarget:self action:@selector(clearLogs) forControlEvents:UIControlEventTouchUpInside];
        [self.panelView addSubview:clearBtn];

        self.summaryLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 38, panelW - 20, 18)];
        self.summaryLabel.font = [UIFont systemFontOfSize:11];
        self.summaryLabel.textColor = [UIColor systemYellowColor];
        self.summaryLabel.text = @"押分：等待 dobet/notice ...";
        [self.panelView addSubview:self.summaryLabel];

        self.resultLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 56, panelW - 20, 18)];
        self.resultLabel.font = [UIFont boldSystemFontOfSize:11];
        self.resultLabel.textColor = [UIColor systemGreenColor];
        self.resultLabel.text = @"开奖：等待 step ...";
        [self.panelView addSubview:self.resultLabel];

        self.statsLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 74, panelW - 20, 16)];
        self.statsLabel.font = [UIFont systemFontOfSize:10];
        self.statsLabel.textColor = [UIColor lightGrayColor];
        [self.panelView addSubview:self.statsLabel];

        self.logTableView = [[UITableView alloc] initWithFrame:CGRectMake(10, 94, panelW - 20, MAX(60, panelH - 99))
                                                        style:UITableViewStylePlain];
        self.logTableView.backgroundColor = [UIColor clearColor];
        self.logTableView.delegate = self;
        self.logTableView.dataSource = self;
        [self.panelView addSubview:self.logTableView];

        [keyWindow addSubview:self.panelView];
        [self refreshSummaryLabels];
        [self refreshStatsLabel];
        [self addLog:@"[启动]" detail:@"调试面板已挂载，HTTP/WebSocket 监听就绪"];
    });
}

- (void)exportLogs {
    if (self.logDataSource.count == 0) return;
    NSMutableString *fullText = [NSMutableString string];
    for (NSDictionary *item in [self.logDataSource reverseObjectEnumerator]) {
        [fullText appendFormat:@"[%@] %@\n%@\n----------------------------------------\n",
         item[@"time"], item[@"title"], item[@"detail"]];
    }
    [UIPasteboard generalPasteboard].string = fullText;

    NSString *fileName = [NSString stringWithFormat:@"debug_log_%.0f.txt", [[NSDate date] timeIntervalSince1970]];
    NSString *filePath = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
    [fullText writeToFile:filePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self presentShareForFile:filePath sourceRect:CGRectMake(10, 5, 80, 30)];
}

- (void)presentShareForFile:(NSString *)path sourceRect:(CGRect)rect {
    if (path.length == 0) return;
    UIViewController *topVC = [self getKeyWindow].rootViewController;
    while (topVC.presentedViewController) topVC = topVC.presentedViewController;
    if (!topVC) return;

    UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]]
                                                                             applicationActivities:nil];
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        activityVC.popoverPresentationController.sourceView = self.panelView;
        activityVC.popoverPresentationController.sourceRect = rect;
    }
    [topVC presentViewController:activityVC animated:YES completion:nil];
}

#pragma mark - WebSocket 解析

- (void)ingestWSMessage:(NSString *)str direction:(NSString *)direction {
    if (![str isKindOfClass:[NSString class]] || str.length == 0) return;
    NSString *trim = [str stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trim.length == 0) return;

    NSString *lower = trim.lowercaseString;
    if ([lower isEqualToString:@"ping"] || [lower isEqualToString:@"pong"] ||
        [lower isEqualToString:@"2"] || [lower isEqualToString:@"3"]) {
        return;
    }

    NSDictionary *json = ACJSONObjectFromString(trim);
    if (json) {
        id cmd = ACFindDeep(json, @"act", 0) ?: ACFindDeep(json, @"c", 0) ?: ACFindDeep(json, @"cmd", 0);
        if ([cmd isKindOfClass:[NSString class]]) {
            NSString *cmdLower = [(NSString *)cmd lowercaseString];
            if ([cmdLower isEqualToString:@"ping"] || [cmdLower isEqualToString:@"pong"]) return;
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL handled = NO;
        if (json) handled = [self handleJSONMessage:json];
        if (handled) return; // 下注通知 / 开奖已转成一行摘要，不重复刷原始 JSON
        NSString *detail = trim.length > 3000 ? [trim substringToIndex:3000] : trim;
        [self addLog:direction detail:detail];
    });
}

- (BOOL)handleJSONMessage:(NSDictionary *)json {
    NSDictionary *dataDict = json;
    id dataObj = json[@"data"];
    if ([dataObj isKindOfClass:[NSDictionary class]]) dataDict = dataObj;

    NSArray<NSNumber *> *bets = ACBetTotalsFromJSON(json);
    if (bets) {
        self.currentBets = bets;
        [self refreshSummaryLabels];
    }

    NSString *act = nil;
    for (NSString *key in @[@"act", @"c", @"cmd", @"type", @"action", @"method"]) {
        id v = dataDict[key];
        if (![v isKindOfClass:[NSString class]]) v = ACFindDeep(json, key, 0);
        if ([v isKindOfClass:[NSString class]]) {
            act = [(NSString *)v lowercaseString];
            break;
        }
    }
    if (act.length == 0) act = @"";

    if ([act containsString:@"dobet/notice"] || [act containsString:@"dobet"]) {
        return YES; // 只更新押分快照，不写日志
    }

    id statusObj = dataDict[@"status"] ?: ACFindDeep(json, @"status", 0);
    NSInteger status = [statusObj respondsToSelector:@selector(integerValue)] ? [statusObj integerValue] : -1;

    id lottery = dataDict[@"lottery"] ?: ACFindDeep(json, @"lottery", 0);
    BOOL isStep = [act containsString:@"step"] || ACFindDeep(json, @"round_result", 0) != nil;
    if (isStep) {
        if (status == 3) {
            self.currentBets = @[@0, @0, @0, @0, @0, @0];
            [self refreshSummaryLabels];
        }
        if ([lottery isKindOfClass:[NSArray class]] && ((NSArray *)lottery).count >= 2) {
            [self recordStepJSON:json lottery:lottery];
            return YES;
        }
    }
    return NO;
}

- (void)recordStepJSON:(NSDictionary *)json lottery:(NSArray *)lottery {
    NSString *round = nil;
    id rr = ACFindDeep(json, @"round_result", 0);
    if ([rr isKindOfClass:[NSDictionary class]]) {
        id roomObj = ACFindDeep(rr, @"room", 0);
        if ([roomObj isKindOfClass:[NSDictionary class]]) {
            id cg = ACFindDeep(roomObj, @"cgidx", 0);
            if ([cg isKindOfClass:[NSNumber class]] || [cg isKindOfClass:[NSString class]]) {
                round = [NSString stringWithFormat:@"%@", cg];
            }
        }
    }
    if (round.length == 0) {
        for (NSString *k in @[@"cgidx", @"round", @"issue", @"qihao", @"expect", @"period"]) {
            id v = ACFindDeep(json, k, 0);
            if ([v isKindOfClass:[NSNumber class]] || [v isKindOfClass:[NSString class]]) {
                round = [NSString stringWithFormat:@"%@", v];
                break;
            }
        }
    }
    if (round.length == 0) {
        round = [NSString stringWithFormat:@"%lu", (unsigned long)(self.roundRecords.count + 1)];
    }

    NSDictionary *last = self.roundRecords.lastObject;
    if (last && [last[@"round"] isEqualToString:round]) return;

    NSInteger d1 = [lottery[0] integerValue];
    NSInteger d2 = [lottery[1] integerValue];

    NSString *room = @"";
    if ([rr isKindOfClass:[NSDictionary class]]) {
        id roomObj = ACFindDeep(rr, @"room", 0);
        if ([roomObj isKindOfClass:[NSDictionary class]]) {
            id num = ACFindDeep(roomObj, @"number", 0);
            if ([num isKindOfClass:[NSNumber class]] || [num isKindOfClass:[NSString class]]) {
                room = [NSString stringWithFormat:@"%@", num];
            }
        }
    }

    id p = nil;
    if ([rr isKindOfClass:[NSDictionary class]]) {
        id banker = ACFindDeep(rr, @"banker", 0);
        if ([banker isKindOfClass:[NSDictionary class]]) {
            p = ACFindDeep(banker, @"profit", 0);
        }
        if (!p) p = ACFindDeep(rr, @"profit", 0) ?: ACFindDeep(rr, @"win", 0);
    } else if ([rr isKindOfClass:[NSNumber class]]) {
        p = rr;
    }
    if (!p) p = ACFindDeep(json, @"profit", 0);
    NSString *profit = ([p isKindOfClass:[NSNumber class]] || [p isKindOfClass:[NSString class]])
        ? [NSString stringWithFormat:@"%@", p] : @"";

    NSArray *bets = [self.currentBets copy] ?: @[@0, @0, @0, @0, @0, @0];
    double totalBets = 0;
    for (int i = 0; i < 6; i++) {
        totalBets += i < (NSInteger)bets.count ? [bets[i] doubleValue] : 0;
    }
    double betOn1 = (d1 >= 1 && d1 <= 6) ? [bets[d1 - 1] doubleValue] : 0;
    double betOn2 = (d2 >= 1 && d2 <= 6) ? [bets[d2 - 1] doubleValue] : 0;
    double returned = (d1 == d2) ? betOn1 * 3.0 : betOn1 * 2.0 + betOn2 * 2.0;
    double expectedProfit = totalBets - returned;

    NSString *verify = @"";
    if (profit.length > 0) {
        double actual = [profit doubleValue];
        double diff = actual - expectedProfit;
        verify = fabs(diff) < 0.5 ? @"✅一致" : [NSString stringWithFormat:@"⚠️差%.0f", diff];
    }

    NSDictionary *record = @{
        @"round": round,
        @"room": room,
        @"bets": bets,
        @"d1": @(d1),
        @"d2": @(d2),
        @"profit": profit,
        @"expect": @(expectedProfit),
        @"verify": verify,
        @"time": [self timestampString]
    };
    [self.roundRecords addObject:record];
    if (self.roundRecords.count > 2000) [self.roundRecords removeObjectAtIndex:0];

    NSString *n1 = ACDiceName(d1), *n2 = ACDiceName(d2);
    for (NSString *name in @[n1, n2]) {
        if (self.statsDict[name]) {
            self.statsDict[name] = @([self.statsDict[name] integerValue] + 1);
        }
    }
    [self saveRecords];

    self.resultLabel.text = [NSString stringWithFormat:@"开奖：%@ + %@   盈亏 %@   第 %@ 局  %@",
                             n1, n2, profit.length ? profit : @"-", round, verify];
    [self refreshStatsLabel];
    [self addLog:@"[开奖]" detail:[NSString stringWithFormat:@"第 %@ 局  开 %@ + %@  盈亏 %@  理论 %.0f  %@\n押分 虎:%.0f 芦:%.0f 狮:%.0f 蟹:%.0f 鱼:%.0f 虾:%.0f",
                                  round, n1, n2, profit.length ? profit : @"-", expectedProfit, verify,
                                  [bets[0] doubleValue], [bets[1] doubleValue], [bets[2] doubleValue],
                                  [bets[3] doubleValue], [bets[4] doubleValue], [bets[5] doubleValue]]];
}

- (void)refreshSummaryLabels {
    NSArray *bets = self.currentBets ?: @[@0, @0, @0, @0, @0, @0];
    NSMutableString *text = [NSMutableString stringWithString:@"押分 "];
    for (int i = 0; i < 6; i++) {
        double v = i < (NSInteger)bets.count ? [bets[i] doubleValue] : 0;
        [text appendFormat:@"%@:%.0f  ", kACBetNames[i], v];
    }
    self.summaryLabel.text = text;
}

- (void)refreshStatsLabel {
    if (!self.statsLabel) return;
    NSMutableString *text = [NSMutableString stringWithFormat:@"共%lu局  ", (unsigned long)self.roundRecords.count];
    for (int i = 0; i < 6; i++) {
        [text appendFormat:@"%@:%@  ", kACBetNames[i], self.statsDict[kACBetNames[i]] ?: @0];
    }
    self.statsLabel.text = text;
}

#pragma mark - 记录持久化与 CSV

- (NSString *)recordsDirectory {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [docs stringByAppendingPathComponent:@"AirChatDebug"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

- (NSString *)timestampString {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    return [fmt stringFromDate:[NSDate date]] ?: @"";
}

- (void)loadRecords {
    NSString *path = [[self recordsDirectory] stringByAppendingPathComponent:@"rounds.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![obj isKindOfClass:[NSArray class]]) return;
    for (id item in (NSArray *)obj) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        [self.roundRecords addObject:item];
        NSString *name1 = ACDiceName([item[@"d1"] integerValue]);
        NSString *name2 = ACDiceName([item[@"d2"] integerValue]);
        for (NSString *name in @[name1, name2]) {
            if (self.statsDict[name]) {
                self.statsDict[name] = @([self.statsDict[name] integerValue] + 1);
            }
        }
    }
    [self refreshStatsLabel];
}

- (void)saveRecords {
    NSArray *snapshot = [self.roundRecords copy];
    NSString *path = [[self recordsDirectory] stringByAppendingPathComponent:@"rounds.json"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
        if (data) [data writeToFile:path atomically:YES];
    });
}

- (void)exportCSV {
    if (self.roundRecords.count == 0) {
        [self addLog:@"[CSV]" detail:@"暂无开奖记录"];
        return;
    }
    NSMutableString *csv = [NSMutableString stringWithString:@"\ufeff时间,房间号,局号,虎总押,芦总押,狮总押,蟹总押,鱼总押,虾总押,开奖1,开奖2,庄家盈亏,理论盈亏,账目校验\n"];
    for (NSDictionary *record in self.roundRecords) {
        NSArray *bets = [record[@"bets"] isKindOfClass:[NSArray class]] ? record[@"bets"] : @[@0, @0, @0, @0, @0, @0];
        NSMutableString *line = [NSMutableString string];
        [line appendFormat:@"%@,%@,%@", ACCsvField(record[@"time"]), ACCsvField(record[@"room"]), ACCsvField(record[@"round"])];
        for (int i = 0; i < 6; i++) {
            double v = i < (NSInteger)bets.count ? [bets[i] doubleValue] : 0;
            [line appendFormat:@",%.0f", v];
        }
        [line appendFormat:@",%@,%@,%@,%.0f,%@",
         ACDiceName([record[@"d1"] integerValue]),
         ACDiceName([record[@"d2"] integerValue]),
         ACCsvField(record[@"profit"]),
         [record[@"expect"] doubleValue],
         ACCsvField(record[@"verify"])];
        [csv appendFormat:@"%@\n", line];
    }

    NSString *fileName = [NSString stringWithFormat:@"rounds_%.0f.csv", [[NSDate date] timeIntervalSince1970]];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
    [csv writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self presentShareForFile:path sourceRect:CGRectMake(94, 5, 60, 30)];
}

- (void)clearLogs {
    [self.logDataSource removeAllObjects];
    if (self.logTableView) [self.logTableView reloadData];
}

- (void)addLog:(NSString *)title detail:(NSString *)detail {
    // 跨线程前先复制，避免调用方临时字符串在异步切换后失效
    NSString *safeTitle = title ? [NSString stringWithFormat:@"%@", title] : @"";
    NSString *safeDetail = detail ? [NSString stringWithFormat:@"%@", detail] : @"";

    dispatch_async(dispatch_get_main_queue(), ^{
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"HH:mm:ss.SSS";
        NSString *timeStr = [fmt stringFromDate:[NSDate date]] ?: @"";

        NSDictionary *item = @{
            @"time": timeStr,
            @"title": safeTitle,
            @"detail": safeDetail
        };
        [self.logDataSource insertObject:item atIndex:0];
        if (self.logDataSource.count > 200) [self.logDataSource removeLastObject];
        if (self.logTableView) [self.logTableView reloadData];
    });
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.floatWindow];
    CGRect frame = self.floatWindow.frame;
    frame.origin.x += translation.x;
    frame.origin.y += translation.y;
    self.floatWindow.frame = frame;
    [pan setTranslation:CGPointMake(0, 0) inView:self.floatWindow];
}

- (void)handlePanelPan:(UIPanGestureRecognizer *)pan {
    UIView *superview = self.panelView.superview;
    if (!superview) return;
    CGPoint translation = [pan translationInView:superview];
    self.panelView.center = CGPointMake(self.panelView.center.x + translation.x,
                                        self.panelView.center.y + translation.y);
    [pan setTranslation:CGPointMake(0, 0) inView:superview];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer.view == self.panelView && touch.view && [touch.view isDescendantOfView:self.logTableView]) {
        return NO; // 列表区域留给滚动
    }
    return YES;
}

- (void)togglePanel {
    if (!self.panelView) [self setupUI];
    self.panelView.hidden = !self.panelView.hidden;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.logDataSource.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"LogCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"LogCell"];
        cell.backgroundColor = [UIColor clearColor];
        cell.textLabel.textColor = [UIColor systemYellowColor];
        cell.textLabel.font = [UIFont boldSystemFontOfSize:11];
        cell.detailTextLabel.textColor = [UIColor whiteColor];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:10];
        cell.detailTextLabel.numberOfLines = 2;
    }
    NSDictionary *item = self.logDataSource[indexPath.row];
    cell.textLabel.text = [NSString stringWithFormat:@"[%@] %@", item[@"time"], item[@"title"]];
    cell.detailTextLabel.text = item[@"detail"];
    return cell;
}

@end

#pragma mark - HTTP 监听

@interface ACHTTPLogProtocol : NSURLProtocol <NSURLConnectionDataDelegate>
@property (nonatomic, strong) NSURLConnection *conn;
@end

static NSString *const kACHTTPHandled = @"ACHTTPHandled";

@implementation ACHTTPLogProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([NSURLProtocol propertyForKey:kACHTTPHandled inRequest:request]) return NO;
    NSString *scheme = request.URL.scheme.lowercaseString;
    return [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSMutableURLRequest *req = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:kACHTTPHandled inRequest:req];

    NSString *body = [[NSString alloc] initWithData:req.HTTPBody encoding:NSUTF8StringEncoding];
    if (body.length > 2000) body = [body substringToIndex:2000];
    [[DebugFloatWindow sharedInstance] addLog:[NSString stringWithFormat:@"[HTTP %@]", req.HTTPMethod ?: @"GET"]
                                       detail:[NSString stringWithFormat:@"%@\n%@", req.URL.absoluteString, body ?: @""]];

    self.conn = [NSURLConnection connectionWithRequest:req delegate:self];
}

- (void)stopLoading {
    [self.conn cancel];
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        [[DebugFloatWindow sharedInstance] addLog:[NSString stringWithFormat:@"[HTTP %ld]", (long)http.statusCode]
                                           detail:http.URL.absoluteString];
    }
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    [self.client URLProtocol:self didLoadData:data];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    [[DebugFloatWindow sharedInstance] addLog:@"[HTTP 失败]" detail:error.localizedDescription ?: @""];
    [self.client URLProtocol:self didFailWithError:error];
}

@end

#pragma mark - WebSocket 监听

@interface NSObject (ACWebSocketLog)
- (void)ac_logSendString:(NSString *)str;
- (void)ac_logWebSocket:(id)ws didReceiveMessageWithString:(NSString *)str;
@end

@implementation NSObject (ACWebSocketLog)

- (void)ac_logSendString:(NSString *)str {
    [[DebugFloatWindow sharedInstance] ingestWSMessage:str direction:@"[WS 发送]"];
    [self ac_logSendString:str];
}

- (void)ac_logWebSocket:(id)ws didReceiveMessageWithString:(NSString *)str {
    [[DebugFloatWindow sharedInstance] ingestWSMessage:str direction:@"[WS 接收]"];
    [self ac_logWebSocket:ws didReceiveMessageWithString:str];
}

@end

static void ACSwizzleMethod(Class cls, SEL origSel, SEL altSel) {
    Method orig = class_getInstanceMethod(cls, origSel);
    Method alt = class_getInstanceMethod([NSObject class], altSel);
    if (!orig || !alt) return;
    method_exchangeImplementations(orig, alt);
}

static BOOL ACHasMethod(Class cls, SEL sel) {
    return class_getInstanceMethod(cls, sel) != NULL;
}

static Class ACFindClassWithMethod(NSString *keyword, SEL sel) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return Nil;
    Class *classes = (Class *)malloc(sizeof(Class) * count);
    if (!classes) return Nil;
    objc_getClassList(classes, count);
    Class result = Nil;
    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        const char *name = class_getName(cls);
        if (!name) continue;
        NSString *clsName = [NSString stringWithUTF8String:name];
        if (keyword.length > 0 && ![clsName containsString:keyword]) continue;
        if (ACHasMethod(cls, sel)) { result = cls; break; }
    }
    free(classes);
    return result;
}

static void ACInstallWebSocketHooks(void) {
    static BOOL installed = NO;
    if (installed) return;

    Class sendCls = ACFindClassWithMethod(@"WebSocket", @selector(sendString:));
    if (!sendCls) sendCls = ACFindClassWithMethod(@"Socket", @selector(sendString:));
    if (!sendCls) {
        Class named = NSClassFromString(@"WebSocketImpl");
        if (named && ACHasMethod(named, @selector(sendString:))) sendCls = named;
    }
    if (sendCls) {
        ACSwizzleMethod(sendCls, @selector(sendString:), @selector(ac_logSendString:));
        [[DebugFloatWindow sharedInstance] addLog:@"[WS Hook]"
                                           detail:[NSString stringWithFormat:@"已挂载发送监听: %s", class_getName(sendCls)]];
    }

    SEL recvSel = NSSelectorFromString(@"webSocket:didReceiveMessageWithString:");
    Class recvCls = ACFindClassWithMethod(@"WebSocket", recvSel);
    if (!recvCls) recvCls = ACFindClassWithMethod(@"Socket", recvSel);
    if (recvCls) {
        ACSwizzleMethod(recvCls, recvSel, @selector(ac_logWebSocket:didReceiveMessageWithString:));
        [[DebugFloatWindow sharedInstance] addLog:@"[WS Hook]"
                                           detail:[NSString stringWithFormat:@"已挂载接收监听: %s", class_getName(recvCls)]];
    }

    if (sendCls || recvCls) {
        installed = YES;
    } else {
        [[DebugFloatWindow sharedInstance] addLog:@"[WS Hook]" detail:@"尚未找到 WebSocket 类，稍后重试"];
    }
}

__attribute__((constructor))
static void ACNetworkLoggerInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [DebugFloatWindow sharedInstance];
        [NSURLProtocol registerClass:[ACHTTPLogProtocol class]];
        ACInstallWebSocketHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ACInstallWebSocketHooks();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            ACInstallWebSocketHooks();
        });
    });
}
