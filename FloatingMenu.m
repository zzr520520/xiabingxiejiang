#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

static NSString * const kACBetNames[6] = {@"虎", @"芦", @"狮", @"蟹", @"鱼", @"虾"};

#pragma mark - JSON 工具

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

static NSString *ACStringValue(id v) {
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([v isKindOfClass:[NSNumber class]]) return [NSString stringWithFormat:@"%@", v];
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

#pragma mark - 面板

@interface DebugFloatWindow : NSObject <UITableViewDelegate, UITableViewDataSource, UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIWindow *floatWindow;
@property (nonatomic, strong) UIButton *floatBtn;
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UISegmentedControl *tabControl;
@property (nonatomic, strong) UITableView *mainTableView;
@property (nonatomic, strong) UIView *analyticsView;
@property (nonatomic, strong) UITextView *analyticsTextView;
@property (nonatomic, strong) UILabel *headerInfoLabel;
@property (nonatomic, strong) UIButton *exportBtn;
@property (nonatomic, strong) UILabel *statsHeaderLabel;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *allSessions;
@property (nonatomic, strong) NSMutableDictionary *activeSession;
@property (nonatomic, strong) NSArray<NSNumber *> *currentBets;
@property (nonatomic, assign) NSInteger currentTabIndex;
+ (instancetype)sharedInstance;
- (void)ingestWSMessage:(NSString *)str direction:(NSString *)direction;
- (void)addLog:(NSString *)title detail:(NSString *)detail;
- (void)refreshAllViews;
- (void)startOrSwitchSessionWithRsn:(NSString *)rsn room:(NSString *)room;
- (BOOL)handleJSONMessage:(NSDictionary *)json;
- (void)recordStepJSON:(NSDictionary *)json lottery:(NSArray *)lottery;
- (void)updateAnalyticsReport;
- (void)onExportTapped;
- (void)exportCurrentSessionCSV;
- (void)exportAllSessionsCSV;
- (UIView *)roundsStatsHeaderView;
- (NSParagraphStyle *)analyticsTabStyle;
- (void)presentShareForFile:(NSString *)path sourceRect:(CGRect)rect;
- (NSString *)dataDirectory;
- (void)saveSessions;
- (void)loadSessions;
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
        _allSessions = [NSMutableArray array];
        _currentBets = @[@0, @0, @0, @0, @0, @0];
        _currentTabIndex = 0;
        [self loadSessions];
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

#pragma mark - 会话模型

- (NSMutableDictionary *)createSessionWithKey:(NSString *)key room:(NSString *)room {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"MM-dd HH:mm";
    return [@{
        @"rsn": key,
        @"room": room.length ? room : @"未知房间",
        @"startTime": [fmt stringFromDate:[NSDate date]] ?: @"",
        @"totalProfit": @0,
        @"rounds": [NSMutableArray array]
    } mutableCopy];
}

- (NSMutableDictionary *)ensureActiveSession {
    if (self.activeSession) return self.activeSession;
    if (self.allSessions.count > 0) {
        self.activeSession = self.allSessions.firstObject;
        return self.activeSession;
    }
    NSMutableDictionary *sess = [self createSessionWithKey:@"DEFAULT" room:@"默认记录"];
    [self.allSessions insertObject:sess atIndex:0];
    self.activeSession = sess;
    [self saveSessions];
    return sess;
}

- (void)startOrSwitchSessionWithRsn:(NSString *)rsn room:(NSString *)room {
    NSString *key = rsn.length ? rsn : (room.length ? [NSString stringWithFormat:@"room_%@", room] : @"DEFAULT");
    for (NSMutableDictionary *sess in self.allSessions) {
        if ([sess[@"rsn"] isEqualToString:key]) {
            if (sess != self.activeSession) {
                self.activeSession = sess;
                [self addLog:@"[场次]" detail:[NSString stringWithFormat:@"切换到 房号:%@", sess[@"room"]]];
            }
            [self refreshAllViews];
            return;
        }
    }
    NSMutableDictionary *sess = [self createSessionWithKey:key room:room];
    [self.allSessions insertObject:sess atIndex:0];
    self.activeSession = sess;
    self.currentBets = @[@0, @0, @0, @0, @0, @0];
    [self saveSessions];
    [self addLog:@"[场次]" detail:[NSString stringWithFormat:@"新建 房号:%@", sess[@"room"]]];
    [self refreshAllViews];
}

#pragma mark - UI

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
        if (!self.floatWindow) self.floatWindow = [[UIWindow alloc] initWithFrame:CGRectMake(20, 80, 50, 50)];
        self.floatWindow.frame = CGRectMake(20, 80, 50, 50);
        self.floatWindow.windowLevel = UIWindowLevelAlert + 1000;
        self.floatWindow.backgroundColor = [UIColor clearColor];
        UIViewController *hostVC = [[UIViewController alloc] init];
        hostVC.view.backgroundColor = [UIColor clearColor];
        self.floatWindow.rootViewController = hostVC;
        self.floatWindow.hidden = NO;

        self.floatBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        self.floatBtn.frame = self.floatWindow.bounds;
        self.floatBtn.backgroundColor = [[UIColor systemIndigoColor] colorWithAlphaComponent:0.9];
        self.floatBtn.layer.cornerRadius = 25;
        [self.floatBtn setTitle:@"数据" forState:UIControlStateNormal];
        self.floatBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
        [self.floatBtn addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *btnPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleBtnPan:)];
        [self.floatBtn addGestureRecognizer:btnPan];
        [hostVC.view addSubview:self.floatBtn];

        CGFloat panelW = MIN(keyWindow.bounds.size.width - 30, 500);
        CGFloat panelH = MIN(keyWindow.bounds.size.height - 50, 340);
        self.panelView = [[UIView alloc] initWithFrame:CGRectMake(15, 30, panelW, panelH)];
        self.panelView.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.93];
        self.panelView.layer.cornerRadius = 12;
        self.panelView.layer.borderWidth = 1;
        self.panelView.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.25].CGColor;
        self.panelView.hidden = YES;
        UIPanGestureRecognizer *panelPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanelPan:)];
        panelPan.delegate = self;
        [self.panelView addGestureRecognizer:panelPan];

        self.headerInfoLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 6, panelW - 140, 24)];
        self.headerInfoLabel.textColor = [UIColor systemYellowColor];
        self.headerInfoLabel.font = [UIFont boldSystemFontOfSize:11];
        [self.panelView addSubview:self.headerInfoLabel];

        UIButton *exportBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        exportBtn.frame = CGRectMake(panelW - 125, 4, 65, 28);
        [exportBtn setTitle:@"导出本场" forState:UIControlStateNormal];
        [exportBtn setTitleColor:[UIColor systemGreenColor] forState:UIControlStateNormal];
        exportBtn.titleLabel.font = [UIFont boldSystemFontOfSize:11];
        [exportBtn addTarget:self action:@selector(onExportTapped) forControlEvents:UIControlEventTouchUpInside];
        self.exportBtn = exportBtn;
        [self.panelView addSubview:exportBtn];

        UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        closeBtn.frame = CGRectMake(panelW - 55, 4, 45, 28);
        [closeBtn setTitle:@"收起" forState:UIControlStateNormal];
        [closeBtn setTitleColor:[UIColor lightGrayColor] forState:UIControlStateNormal];
        closeBtn.titleLabel.font = [UIFont systemFontOfSize:11];
        [closeBtn addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
        [self.panelView addSubview:closeBtn];

        self.tabControl = [[UISegmentedControl alloc] initWithItems:@[@"本场局明细", @"房间场次", @"押分与命中率"]];
        self.tabControl.frame = CGRectMake(10, 34, panelW - 20, 28);
        self.tabControl.selectedSegmentIndex = 0;
        self.tabControl.backgroundColor = [[UIColor darkGrayColor] colorWithAlphaComponent:0.5];
        [self.tabControl setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor whiteColor],
                                                  NSFontAttributeName: [UIFont boldSystemFontOfSize:11]}
                                       forState:UIControlStateNormal];
        [self.tabControl setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor blackColor],
                                                  NSFontAttributeName: [UIFont boldSystemFontOfSize:11]}
                                       forState:UIControlStateSelected];
        [self.tabControl addTarget:self action:@selector(onTabChanged:) forControlEvents:UIControlEventValueChanged];
        [self.panelView addSubview:self.tabControl];

        CGRect content = CGRectMake(10, 68, panelW - 20, panelH - 74);
        self.mainTableView = [[UITableView alloc] initWithFrame:content style:UITableViewStylePlain];
        self.mainTableView.backgroundColor = [UIColor clearColor];
        self.mainTableView.separatorColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
        self.mainTableView.delegate = self;
        self.mainTableView.dataSource = self;
        [self.panelView addSubview:self.mainTableView];

        self.analyticsView = [[UIView alloc] initWithFrame:content];
        self.analyticsView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.05];
        self.analyticsView.layer.cornerRadius = 8;
        self.analyticsView.hidden = YES;
        self.analyticsTextView = [[UITextView alloc] initWithFrame:CGRectMake(6, 4, content.size.width - 12, content.size.height - 8)];
        self.analyticsTextView.backgroundColor = [UIColor clearColor];
        self.analyticsTextView.textColor = [UIColor whiteColor];
        self.analyticsTextView.font = [UIFont systemFontOfSize:11];
        self.analyticsTextView.editable = NO;
        [self.analyticsView addSubview:self.analyticsTextView];
        [self.panelView addSubview:self.analyticsView];

        [keyWindow addSubview:self.panelView];
        [self refreshAllViews];
        [self addLog:@"[启动]" detail:@"调试面板已挂载"];
    });
}

- (void)onTabChanged:(UISegmentedControl *)sender {
    self.currentTabIndex = sender.selectedSegmentIndex;
    [self refreshAllViews];
}

- (void)refreshAllViews {
    if (!self.mainTableView) return;
    NSMutableDictionary *sess = [self ensureActiveSession];
    NSArray *rounds = [sess[@"rounds"] isKindOfClass:[NSArray class]] ? sess[@"rounds"] : @[];
    if (self.headerInfoLabel) {
        self.headerInfoLabel.text = [NSString stringWithFormat:@"房号:%@ | 已开%lu局 | 庄总盈:%@",
                                     sess[@"room"] ?: @"-", (unsigned long)rounds.count, sess[@"totalProfit"] ?: @0];
    }
    if (self.exportBtn) {
        [self.exportBtn setTitle:(self.currentTabIndex == 1 ? @"全选导出" : @"导出本场")
                        forState:UIControlStateNormal];
    }
    if (self.currentTabIndex == 2) {
        self.mainTableView.hidden = YES;
        self.analyticsView.hidden = NO;
        [self updateAnalyticsReport];
    } else {
        self.mainTableView.hidden = NO;
        self.analyticsView.hidden = YES;
        self.mainTableView.tableHeaderView = (self.currentTabIndex == 0) ? [self roundsStatsHeaderView] : nil;
        [self.mainTableView reloadData];
    }
}

- (void)onExportTapped {
    if (self.currentTabIndex == 1) {
        [self exportAllSessionsCSV];
    } else {
        [self exportCurrentSessionCSV];
    }
}

- (void)togglePanel {
    if (!self.panelView) [self setupUI];
    self.panelView.hidden = !self.panelView.hidden;
    if (!self.panelView.hidden) [self refreshAllViews];
}

#pragma mark - 消息解析

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
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL handled = json ? [self handleJSONMessage:json] : NO;
        if (!handled) {
            NSString *detail = trim.length > 3000 ? [trim substringToIndex:3000] : trim;
            [self addLog:direction detail:detail];
        }
    });
}

- (BOOL)handleJSONMessage:(NSDictionary *)json {
    NSDictionary *data = json;
    id dataObj = json[@"data"];
    if ([dataObj isKindOfClass:[NSDictionary class]]) data = dataObj;

    NSString *act = nil;
    for (NSString *key in @[@"act", @"c", @"cmd", @"type", @"action", @"method"]) {
        NSString *v = ACStringValue(data[key]) ?: ACStringValue(ACFindDeep(json, key, 0));
        if (v.length) { act = v.lowercaseString; break; }
    }
    if (!act) act = @"";

    // 进房 / 建房：按 rsn 独立建档
    if ([act containsString:@"room/create"] || [act containsString:@"yuxia/join"] || [act containsString:@"join"]) {
        id roomObj = data[@"room"];
        NSDictionary *room = [roomObj isKindOfClass:[NSDictionary class]] ? roomObj : nil;
        NSString *rsn = ACStringValue(room[@"rsn"]) ?: ACStringValue(ACFindDeep(json, @"rsn", 0));
        NSString *num = ACStringValue(room[@"number"]) ?: ACStringValue(ACFindDeep(json, @"number", 0));
        if (rsn.length || num.length) [self startOrSwitchSessionWithRsn:rsn room:num];
        return YES;
    }

    // 押分快照
    NSArray<NSNumber *> *bets = ACBetTotalsFromJSON(json);
    if (bets) self.currentBets = bets;
    if ([act containsString:@"dobet/notice"] || [act containsString:@"dobet"]) return YES;

    id statusObj = data[@"status"] ?: ACFindDeep(json, @"status", 0);
    NSInteger status = [statusObj respondsToSelector:@selector(integerValue)] ? [statusObj integerValue] : -1;
    id lottery = data[@"lottery"] ?: ACFindDeep(json, @"lottery", 0);

    if ([act containsString:@"step"]) {
        if (status == 3) {
            self.currentBets = @[@0, @0, @0, @0, @0, @0];
            return YES;
        }
        if ([lottery isKindOfClass:[NSArray class]] && ((NSArray *)lottery).count >= 2) {
            [self recordStepJSON:json lottery:lottery];
            return YES;
        }
    }
    return NO;
}

- (void)recordStepJSON:(NSDictionary *)json lottery:(NSArray *)lottery {
    id rr = ACFindDeep(json, @"round_result", 0);
    NSDictionary *roundResult = [rr isKindOfClass:[NSDictionary class]] ? rr : nil;

    // 开奖包本身也带房号，先确保场次正确
    if (roundResult) {
        id roomObj = ACFindDeep(roundResult, @"room", 0);
        if ([roomObj isKindOfClass:[NSDictionary class]]) {
            NSString *rsn = ACStringValue(((NSDictionary *)roomObj)[@"rsn"]);
            NSString *num = ACStringValue(((NSDictionary *)roomObj)[@"number"]);
            if (rsn.length || num.length) [self startOrSwitchSessionWithRsn:rsn room:num];
        }
    }

    NSMutableDictionary *sess = [self ensureActiveSession];
    NSMutableArray *rounds = sess[@"rounds"];
    if (![rounds isKindOfClass:[NSMutableArray class]]) {
        rounds = [NSMutableArray array];
        sess[@"rounds"] = rounds;
    }

    NSString *round = nil;
    if (roundResult) {
        id roomObj = ACFindDeep(roundResult, @"room", 0);
        if ([roomObj isKindOfClass:[NSDictionary class]]) {
            round = ACStringValue(((NSDictionary *)roomObj)[@"cgidx"]);
        }
    }
    if (round.length == 0) {
        for (NSString *k in @[@"cgidx", @"round", @"issue", @"qihao", @"expect", @"period"]) {
            NSString *v = ACStringValue(ACFindDeep(json, k, 0));
            if (v.length) { round = v; break; }
        }
    }
    if (round.length == 0) round = [NSString stringWithFormat:@"%lu", (unsigned long)(rounds.count + 1)];

    NSDictionary *newest = rounds.firstObject;
    if (newest && [newest[@"round"] isEqualToString:round]) return;

    NSInteger d1 = [lottery[0] integerValue];
    NSInteger d2 = [lottery[1] integerValue];
    NSString *n1 = ACDiceName(d1), *n2 = ACDiceName(d2);

    id p = nil;
    if (roundResult) {
        id banker = ACFindDeep(roundResult, @"banker", 0);
        if ([banker isKindOfClass:[NSDictionary class]]) p = ACFindDeep(banker, @"profit", 0);
        if (!p) p = ACFindDeep(roundResult, @"profit", 0) ?: ACFindDeep(roundResult, @"win", 0);
    } else if ([rr isKindOfClass:[NSNumber class]]) {
        p = rr;
    }
    if (!p) p = ACFindDeep(json, @"profit", 0);
    NSString *profit = ACStringValue(p) ?: @"";

    NSArray *bets = [self.currentBets copy] ?: @[@0, @0, @0, @0, @0, @0];
    double totalBets = 0;
    for (int i = 0; i < 6; i++) totalBets += [bets[i] doubleValue];
    double bet1 = (d1 >= 1 && d1 <= 6) ? [bets[d1 - 1] doubleValue] : 0;
    double bet2 = (d2 >= 1 && d2 <= 6) ? [bets[d2 - 1] doubleValue] : 0;
    double returned = (d1 == d2) ? bet1 * 3.0 : bet1 * 2.0 + bet2 * 2.0;
    double expected = totalBets - returned;

    NSString *verify = @"";
    if (profit.length) {
        double diff = [profit doubleValue] - expected;
        verify = fabs(diff) < 0.5 ? @"✅一致" : [NSString stringWithFormat:@"⚠️差%.0f", diff];
    }

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss";
    NSDictionary *item = @{
        @"time": [fmt stringFromDate:[NSDate date]] ?: @"",
        @"round": round,
        @"bets": bets,
        @"d1": @(d1),
        @"d2": @(d2),
        @"profit": profit,
        @"expect": @(expected),
        @"verify": verify
    };
    [rounds insertObject:item atIndex:0];
    sess[@"totalProfit"] = @([sess[@"totalProfit"] doubleValue] + [profit doubleValue]);
    [self saveSessions];
    [self refreshAllViews];

    [self addLog:@"[开奖]" detail:[NSString stringWithFormat:@"房%@ 第%@局 %@+%@ 盈%@ 理论%.0f %@",
                                  sess[@"room"], round, n1, n2, profit.length ? profit : @"-", expected, verify]];
}

#pragma mark - 命中率分析

- (void)updateAnalyticsReport {
    NSMutableDictionary *sess = [self ensureActiveSession];
    NSArray *rounds = [sess[@"rounds"] isKindOfClass:[NSArray class]] ? sess[@"rounds"] : @[];
    NSInteger total = rounds.count;
    if (total == 0) {
        self.analyticsTextView.text = @"当前房间暂无开奖数据。\n完成一局开奖后这里会自动统计。";
        return;
    }

    NSArray *keys = @[@"b1", @"b2", @"b3", @"b4", @"b5", @"b6"];
    NSInteger hits[6] = {0};
    NSInteger diceCounts[6] = {0};
    double betSums[6] = {0};
    NSInteger heavyHit = 0, heavyValid = 0, sameCount = 0;

    for (NSDictionary *r in rounds) {
        NSInteger d1 = [r[@"d1"] integerValue];
        NSInteger d2 = [r[@"d2"] integerValue];
        if (d1 == d2) sameCount++;
        if (d1 >= 1 && d1 <= 6) { hits[d1 - 1]++; diceCounts[d1 - 1]++; }
        if (d2 >= 1 && d2 <= 6) { diceCounts[d2 - 1]++; if (d2 != d1) hits[d2 - 1]++; }

        NSArray *bets = [r[@"bets"] isKindOfClass:[NSArray class]] ? r[@"bets"] : @[];
        double maxBet = 0;
        NSInteger maxIdx = -1;
        for (int i = 0; i < 6; i++) {
            double v = i < (NSInteger)bets.count ? [bets[i] doubleValue] : 0;
            betSums[i] += v;
            if (v > maxBet) { maxBet = v; maxIdx = i; }
        }
        if (maxBet > 0 && maxIdx >= 0) {
            heavyValid++;
            if ((d1 - 1) == maxIdx || (d2 - 1) == maxIdx) heavyHit++;
        }
    }

    UIFont *font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    UIFont *boldFont = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightBold];
    NSMutableParagraphStyle *plainStyle = [[NSMutableParagraphStyle alloc] init];
    plainStyle.lineSpacing = 2;
    NSDictionary *plainAttr = @{NSFontAttributeName: font,
                                NSForegroundColorAttributeName: [UIColor whiteColor],
                                NSParagraphStyleAttributeName: plainStyle};
    NSDictionary *titleAttr = @{NSFontAttributeName: boldFont,
                                NSForegroundColorAttributeName: [UIColor systemYellowColor],
                                NSParagraphStyleAttributeName: plainStyle};
    NSDictionary *rowAttr = @{NSFontAttributeName: font,
                              NSForegroundColorAttributeName: [UIColor whiteColor],
                              NSParagraphStyleAttributeName: [self analyticsTabStyle]};
    NSDictionary *headAttr = @{NSFontAttributeName: boldFont,
                               NSForegroundColorAttributeName: [UIColor systemYellowColor],
                               NSParagraphStyleAttributeName: [self analyticsTabStyle]};

    NSMutableAttributedString *report = [[NSMutableAttributedString alloc] initWithString:@""];
    [report appendAttributedString:[[NSAttributedString alloc] initWithString:
        [NSString stringWithFormat:@"房间 %@   共 %ld 局\n", sess[@"room"], (long)total] attributes:titleAttr]];
    [report appendAttributedString:[[NSAttributedString alloc] initWithString:
        [NSString stringWithFormat:@"庄累计盈亏：%@   同点局：%ld\n", sess[@"totalProfit"], (long)sameCount] attributes:plainAttr]];
    if (heavyValid > 0) {
        [report appendAttributedString:[[NSAttributedString alloc] initWithString:
            [NSString stringWithFormat:@"最大押分门命中率：%.1f%% (%ld/%ld)\n",
             (double)heavyHit / heavyValid * 100.0, (long)heavyHit, (long)heavyValid] attributes:plainAttr]];
    }
    [report appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:plainAttr]];
    [report appendAttributedString:[[NSAttributedString alloc] initWithString:
        @"门类\t押分\t骰数\t局命中\t命中率\n" attributes:headAttr]];
    for (int i = 0; i < 6; i++) {
        NSString *line = [NSString stringWithFormat:@"%@\t%.0f\t%ld\t%ld\t%.1f%%\n",
                          kACBetNames[i], betSums[i], (long)diceCounts[i], (long)hits[i],
                          (double)hits[i] / total * 100.0];
        [report appendAttributedString:[[NSAttributedString alloc] initWithString:line attributes:rowAttr]];
    }
    [report appendAttributedString:[[NSAttributedString alloc] initWithString:
        @"\n理论参考：单门至少出现一次 30.6%%\n" attributes:plainAttr]];
    [report appendAttributedString:[[NSAttributedString alloc] initWithString:
        [NSString stringWithFormat:@"样本量 %ld 局，偏差需上百局才有统计意义。", (long)total] attributes:plainAttr]];
    self.analyticsTextView.attributedText = report;
}

- (NSParagraphStyle *)analyticsTabStyle {
    CGFloat w = MAX(self.analyticsTextView.bounds.size.width - 10, 240);
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    NSMutableArray<NSTextTab *> *tabs = [NSMutableArray array];
    CGFloat fracs[4] = {0.22, 0.46, 0.66, 0.82};
    for (int i = 0; i < 4; i++) {
        [tabs addObject:[[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentLeft
                                                        location:w * fracs[i]
                                                         options:@{}]];
    }
    ps.tabStops = tabs;
    ps.lineSpacing = 2;
    return ps;
}

#pragma mark - 本场出现次数统计

- (UIView *)roundsStatsHeaderView {
    NSArray *rounds = [self ensureActiveSession][@"rounds"];
    if (![rounds isKindOfClass:[NSArray class]]) rounds = @[];

    NSInteger counts[6] = {0};
    for (NSDictionary *r in rounds) {
        NSInteger d1 = [r[@"d1"] integerValue];
        NSInteger d2 = [r[@"d2"] integerValue];
        if (d1 >= 1 && d1 <= 6) counts[d1 - 1]++;
        if (d2 >= 1 && d2 <= 6) counts[d2 - 1]++;
    }

    NSMutableString *text = [NSMutableString stringWithFormat:@"本场共 %lu 局  出现次数：",
                             (unsigned long)rounds.count];
    for (int i = 0; i < 6; i++) {
        [text appendFormat:@"%@%ld  ", kACBetNames[i], (long)counts[i]];
    }

    if (!self.statsHeaderLabel) {
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectZero];
        lbl.numberOfLines = 0;
        lbl.font = [UIFont systemFontOfSize:10];
        lbl.textColor = [UIColor systemYellowColor];
        lbl.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.06];
        self.statsHeaderLabel = lbl;
    }
    self.statsHeaderLabel.text = text;
    CGFloat w = self.mainTableView.bounds.size.width;
    CGSize fit = [self.statsHeaderLabel sizeThatFits:CGSizeMake(w - 8, CGFLOAT_MAX)];
    self.statsHeaderLabel.frame = CGRectMake(0, 0, w, fit.height + 6);
    return self.statsHeaderLabel;
}

#pragma mark - 表格

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.currentTabIndex == 0) {
        NSArray *rounds = [self ensureActiveSession][@"rounds"];
        return [rounds isKindOfClass:[NSArray class]] ? rounds.count : 0;
    }
    return self.allSessions.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 46.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"DataCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"DataCell"];
        cell.backgroundColor = [UIColor clearColor];
        cell.selectionStyle = UITableViewCellSelectionStyleGray;
        cell.textLabel.font = [UIFont boldSystemFontOfSize:11];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:10];
        cell.detailTextLabel.textColor = [UIColor lightGrayColor];
    }

    if (self.currentTabIndex == 0) {
        NSArray *rounds = [self ensureActiveSession][@"rounds"];
        NSDictionary *r = rounds[indexPath.row];
        cell.textLabel.textColor = [UIColor systemGreenColor];
        cell.textLabel.text = [NSString stringWithFormat:@"[%@] 第%@局 [%@+%@] 盈:%@ %@",
                               r[@"time"], r[@"round"], ACDiceName([r[@"d1"] integerValue]),
                               ACDiceName([r[@"d2"] integerValue]), r[@"profit"], r[@"verify"]];
        NSArray *bets = [r[@"bets"] isKindOfClass:[NSArray class]] ? r[@"bets"] : @[];
        NSMutableString *detail = [NSMutableString stringWithString:@"押分 "];
        for (int i = 0; i < 6 && i < (NSInteger)bets.count; i++) {
            [detail appendFormat:@"%@:%.0f ", kACBetNames[i], [bets[i] doubleValue]];
        }
        cell.detailTextLabel.text = detail;
    } else {
        NSMutableDictionary *sess = self.allSessions[indexPath.row];
        BOOL isCurrent = (sess == self.activeSession);
        NSArray *rounds = [sess[@"rounds"] isKindOfClass:[NSArray class]] ? sess[@"rounds"] : @[];
        cell.textLabel.textColor = isCurrent ? [UIColor systemYellowColor] : [UIColor whiteColor];
        cell.textLabel.text = [NSString stringWithFormat:@"%@房%@ (%@) %lu局 盈:%@",
                               isCurrent ? @"👉" : @"", sess[@"room"], sess[@"startTime"],
                               (unsigned long)rounds.count, sess[@"totalProfit"]];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"rsn:%@  左滑可删除", sess[@"rsn"]];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.currentTabIndex == 1 && indexPath.row < (NSInteger)self.allSessions.count) {
        self.activeSession = self.allSessions[indexPath.row];
        self.currentTabIndex = 0;
        self.tabControl.selectedSegmentIndex = 0;
        [self refreshAllViews];
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return self.currentTabIndex == 1;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete || self.currentTabIndex != 1) return;
    if (indexPath.row >= (NSInteger)self.allSessions.count) return;
    NSMutableDictionary *target = self.allSessions[indexPath.row];
    [self.allSessions removeObjectAtIndex:indexPath.row];
    if (target == self.activeSession) {
        self.activeSession = self.allSessions.count ? self.allSessions.firstObject : nil;
    }
    [self saveSessions];
    [self refreshAllViews];
}

#pragma mark - 持久化

- (NSString *)dataDirectory {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [docs stringByAppendingPathComponent:@"AirChatDebug"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

- (void)saveSessions {
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.allSessions options:0 error:nil];
    if (!data) return;
    NSString *path = [[self dataDirectory] stringByAppendingPathComponent:@"sessions.json"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [data writeToFile:path atomically:YES];
    });
}

- (void)loadSessions {
    NSString *path = [[self dataDirectory] stringByAppendingPathComponent:@"sessions.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data) {
        id obj = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
        if ([obj isKindOfClass:[NSArray class]]) {
            for (id item in (NSArray *)obj) {
                if (![item isKindOfClass:[NSMutableDictionary class]]) continue;
                NSMutableDictionary *sess = item;
                if (![sess[@"rounds"] isKindOfClass:[NSMutableArray class]]) {
                    sess[@"rounds"] = [NSMutableArray array];
                }
                [self.allSessions addObject:sess];
            }
        }
        self.activeSession = self.allSessions.firstObject;
        return;
    }

    // 迁移旧版单场记录
    NSString *legacy = [[self dataDirectory] stringByAppendingPathComponent:@"rounds.json"];
    NSData *legacyData = [NSData dataWithContentsOfFile:legacy];
    if (!legacyData) return;
    id obj = [NSJSONSerialization JSONObjectWithData:legacyData options:NSJSONReadingMutableContainers error:nil];
    if (![obj isKindOfClass:[NSArray class]] || ((NSArray *)obj).count == 0) return;
    NSMutableDictionary *sess = [self createSessionWithKey:@"legacy" room:@"默认记录"];
    NSMutableArray *rounds = [NSMutableArray array];
    double totalProfit = 0;
    for (id item in (NSArray *)obj) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        [rounds addObject:item];
        totalProfit += [item[@"profit"] doubleValue];
    }
    sess[@"rounds"] = rounds;
    sess[@"totalProfit"] = @(totalProfit);
    [self.allSessions addObject:sess];
    self.activeSession = sess;
}

#pragma mark - CSV

- (void)presentShareForFile:(NSString *)path sourceRect:(CGRect)rect {
    UIViewController *topVC = [self getKeyWindow].rootViewController;
    while (topVC.presentedViewController) topVC = topVC.presentedViewController;
    if (!topVC) return;
    UIActivityViewController *vc = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:path]]
                                                                     applicationActivities:nil];
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        vc.popoverPresentationController.sourceView = self.panelView;
        vc.popoverPresentationController.sourceRect = rect;
    }
    [topVC presentViewController:vc animated:YES completion:nil];
}

- (void)exportCurrentSessionCSV {
    NSMutableDictionary *sess = [self ensureActiveSession];
    NSArray *rounds = [sess[@"rounds"] isKindOfClass:[NSArray class]] ? sess[@"rounds"] : @[];
    if (rounds.count == 0) {
        [self addLog:@"[CSV]" detail:@"当前场次暂无开奖记录"];
        return;
    }
    NSMutableString *csv = [NSMutableString stringWithString:@"\ufeff时间,房间号,局号,虎总押,芦总押,狮总押,蟹总押,鱼总押,虾总押,开奖1,开奖2,庄家盈亏,理论盈亏,账目校验\n"];
    for (NSDictionary *r in [rounds reverseObjectEnumerator]) {
        NSArray *bets = [r[@"bets"] isKindOfClass:[NSArray class]] ? r[@"bets"] : @[@0, @0, @0, @0, @0, @0];
        NSMutableString *line = [NSMutableString string];
        [line appendFormat:@"%@,%@,%@", ACCsvField(r[@"time"]), ACCsvField(sess[@"room"]), ACCsvField(r[@"round"])];
        for (int i = 0; i < 6; i++) {
            double v = i < (NSInteger)bets.count ? [bets[i] doubleValue] : 0;
            [line appendFormat:@",%.0f", v];
        }
        [line appendFormat:@",%@,%@,%@,%.0f,%@",
         ACDiceName([r[@"d1"] integerValue]),
         ACDiceName([r[@"d2"] integerValue]),
         ACCsvField(r[@"profit"]),
         [r[@"expect"] doubleValue],
         ACCsvField(r[@"verify"])];
        [csv appendFormat:@"%@\n", line];
    }

    NSString *fileName = [NSString stringWithFormat:@"room_%@_%.0f.csv", sess[@"room"], [[NSDate date] timeIntervalSince1970]];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
    [csv writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self presentShareForFile:path sourceRect:CGRectMake(self.panelView.bounds.size.width - 125, 4, 65, 28)];
}

- (void)exportAllSessionsCSV {
    if (self.allSessions.count == 0) {
        [self addLog:@"[CSV]" detail:@"暂无任何场次记录"];
        return;
    }
    NSMutableString *csv = [NSMutableString stringWithString:
        @"\ufeff场次rsn,房间号,开赛时间,局时间,局号,虎总押,芦总押,狮总押,蟹总押,鱼总押,虾总押,开奖1,开奖2,庄家盈亏,理论盈亏,账目校验\n"];
    NSInteger rowCount = 0;
    for (NSDictionary *sess in self.allSessions) {
        NSArray *rounds = [sess[@"rounds"] isKindOfClass:[NSArray class]] ? sess[@"rounds"] : @[];
        for (NSDictionary *r in [rounds reverseObjectEnumerator]) {
            NSArray *bets = [r[@"bets"] isKindOfClass:[NSArray class]] ? r[@"bets"] : @[@0, @0, @0, @0, @0, @0];
            NSMutableString *line = [NSMutableString string];
            [line appendFormat:@"%@,%@,%@,%@,%@",
             ACCsvField(sess[@"rsn"]), ACCsvField(sess[@"room"]),
             ACCsvField(sess[@"startTime"]), ACCsvField(r[@"time"]), ACCsvField(r[@"round"])];
            for (int i = 0; i < 6; i++) {
                double v = i < (NSInteger)bets.count ? [bets[i] doubleValue] : 0;
                [line appendFormat:@",%.0f", v];
            }
            [line appendFormat:@",%@,%@,%@,%.0f,%@",
             ACDiceName([r[@"d1"] integerValue]),
             ACDiceName([r[@"d2"] integerValue]),
             ACCsvField(r[@"profit"]),
             [r[@"expect"] doubleValue],
             ACCsvField(r[@"verify"])];
            [csv appendFormat:@"%@\n", line];
            rowCount++;
        }
    }
    if (rowCount == 0) {
        [self addLog:@"[CSV]" detail:@"所有场次均无开奖记录"];
        return;
    }

    NSString *fileName = [NSString stringWithFormat:@"all_sessions_%.0f.csv", [[NSDate date] timeIntervalSince1970]];
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
    [csv writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self presentShareForFile:path sourceRect:CGRectMake(self.panelView.bounds.size.width - 125, 4, 65, 28)];
}

#pragma mark - 拖动

- (void)handleBtnPan:(UIPanGestureRecognizer *)pan {
    CGPoint t = [pan translationInView:self.floatWindow];
    CGRect frame = self.floatWindow.frame;
    frame.origin.x += t.x;
    frame.origin.y += t.y;
    self.floatWindow.frame = frame;
    [pan setTranslation:CGPointMake(0, 0) inView:self.floatWindow];
}

- (void)handlePanelPan:(UIPanGestureRecognizer *)pan {
    UIView *superview = self.panelView.superview;
    if (!superview) return;
    CGPoint t = [pan translationInView:superview];
    self.panelView.center = CGPointMake(self.panelView.center.x + t.x, self.panelView.center.y + t.y);
    [pan setTranslation:CGPointMake(0, 0) inView:superview];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer.view == self.panelView && touch.view) {
        if ([touch.view isDescendantOfView:self.mainTableView]) return NO;
        if ([touch.view isDescendantOfView:self.analyticsTextView]) return NO;
    }
    return YES;
}

- (void)addLog:(NSString *)title detail:(NSString *)detail {
    NSLog(@"[FloatingMenu] %@ %@", title, detail);
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

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }

- (void)startLoading {
    NSMutableURLRequest *req = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:kACHTTPHandled inRequest:req];
    NSString *body = [[NSString alloc] initWithData:req.HTTPBody encoding:NSUTF8StringEncoding];
    if (body.length > 1000) body = [body substringToIndex:1000];
    [[DebugFloatWindow sharedInstance] addLog:[NSString stringWithFormat:@"[HTTP %@]", req.HTTPMethod ?: @"GET"]
                                       detail:[NSString stringWithFormat:@"%@ %@", req.URL.absoluteString, body ?: @""]];
    self.conn = [NSURLConnection connectionWithRequest:req delegate:self];
}

- (void)stopLoading { [self.conn cancel]; }

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    [self.client URLProtocol:self didLoadData:data];
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    [self.client URLProtocol:self didFailWithError:error];
}

@end

#pragma mark - WebSocket Hook

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
    if (sendCls) {
        ACSwizzleMethod(sendCls, @selector(sendString:), @selector(ac_logSendString:));
        NSLog(@"[FloatingMenu] WS 发送监听: %s", class_getName(sendCls));
    }

    SEL recvSel = NSSelectorFromString(@"webSocket:didReceiveMessageWithString:");
    Class recvCls = ACFindClassWithMethod(@"WebSocket", recvSel);
    if (!recvCls) recvCls = ACFindClassWithMethod(@"Socket", recvSel);
    if (recvCls) {
        ACSwizzleMethod(recvCls, recvSel, @selector(ac_logWebSocket:didReceiveMessageWithString:));
        NSLog(@"[FloatingMenu] WS 接收监听: %s", class_getName(recvCls));
    }

    if (sendCls || recvCls) installed = YES;
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
