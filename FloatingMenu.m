#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <stdlib.h>

#pragma mark - 日志窗口

@interface DebugFloatWindow : NSObject <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UIWindow *floatWindow;
@property (nonatomic, strong) UIButton *floatBtn;
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UITableView *logTableView;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *logDataSource;
+ (instancetype)sharedInstance;
- (void)addLog:(NSString *)title detail:(NSString *)detail;
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
        [self.floatWindow addSubview:self.floatBtn];

        CGFloat panelW = MIN(keyWindow.bounds.size.width - 40, 420);
        CGFloat panelH = MIN(keyWindow.bounds.size.height - 80, 280);
        self.panelView = [[UIView alloc] initWithFrame:CGRectMake(20, 60, panelW, panelH)];
        self.panelView.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.88];
        self.panelView.layer.cornerRadius = 10;
        self.panelView.hidden = YES;

        UIButton *exportBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        exportBtn.frame = CGRectMake(10, 5, 80, 30);
        [exportBtn setTitle:@"导出日志" forState:UIControlStateNormal];
        [exportBtn setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
        exportBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
        [exportBtn addTarget:self action:@selector(exportLogs) forControlEvents:UIControlEventTouchUpInside];
        [self.panelView addSubview:exportBtn];

        UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        clearBtn.frame = CGRectMake(100, 5, 50, 30);
        [clearBtn setTitle:@"清空" forState:UIControlStateNormal];
        [clearBtn setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
        clearBtn.titleLabel.font = [UIFont systemFontOfSize:12];
        [clearBtn addTarget:self action:@selector(clearLogs) forControlEvents:UIControlEventTouchUpInside];
        [self.panelView addSubview:clearBtn];

        self.logTableView = [[UITableView alloc] initWithFrame:CGRectMake(10, 40, panelW - 20, panelH - 45)
                                                        style:UITableViewStylePlain];
        self.logTableView.backgroundColor = [UIColor clearColor];
        self.logTableView.delegate = self;
        self.logTableView.dataSource = self;
        [self.panelView addSubview:self.logTableView];

        [keyWindow addSubview:self.panelView];
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

    UIViewController *topVC = [self getKeyWindow].rootViewController;
    while (topVC.presentedViewController) topVC = topVC.presentedViewController;
    if (!topVC) return;

    UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:filePath]]
                                                                             applicationActivities:nil];
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
        activityVC.popoverPresentationController.sourceView = self.panelView;
        activityVC.popoverPresentationController.sourceRect = CGRectMake(10, 10, 80, 30);
    }
    [topVC presentViewController:activityVC animated:YES completion:nil];
}

- (void)clearLogs {
    [self.logDataSource removeAllObjects];
    [self.logTableView reloadData];
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
    [[DebugFloatWindow sharedInstance] addLog:@"[WS 发送]" detail:str ?: @""];
    [self ac_logSendString:str];
}

- (void)ac_logWebSocket:(id)ws didReceiveMessageWithString:(NSString *)str {
    [[DebugFloatWindow sharedInstance] addLog:@"[WS 接收]" detail:str ?: @""];
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
