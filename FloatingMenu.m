#import <UIKit/UIKit.h>

static UIButton *gFloatingButton = nil;

@interface FloatingMenuView : UIButton
+ (void)showFloatingButton;
@end

@implementation FloatingMenuView

+ (UIWindow *)ac_keyWindow {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) return w;
            }
        }
        return nil;
    }
    return nil;
}

+ (void)showFloatingButton {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gFloatingButton && gFloatingButton.superview) return;
        UIWindow *keyWindow = [self ac_keyWindow];
        if (!keyWindow) return;

        FloatingMenuView *btn = [[FloatingMenuView alloc] initWithFrame:CGRectMake(20, 120, 56, 56)];
        btn.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.72];
        btn.layer.cornerRadius = 28;
        btn.layer.masksToBounds = YES;
        btn.layer.borderWidth = 1.0;
        btn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.25].CGColor;
        [btn setTitle:@"菜单" forState:UIControlStateNormal];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:btn action:@selector(handlePan:)];
        [btn addGestureRecognizer:pan];
        [btn addTarget:btn action:@selector(onMenuClicked) forControlEvents:UIControlEventTouchUpInside];

        [keyWindow addSubview:btn];
        [keyWindow bringSubviewToFront:btn];
        gFloatingButton = btn;
        NSLog(@"[FloatingMenu] 悬浮按钮已挂载");
    });
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self.superview];
    self.center = CGPointMake(self.center.x + translation.x, self.center.y + translation.y);
    [pan setTranslation:CGPointMake(0, 0) inView:self.superview];
}

- (void)onMenuClicked {
    UIViewController *topVC = [FloatingMenuView ac_keyWindow].rootViewController;
    while (topVC.presentedViewController) topVC = topVC.presentedViewController;
    if (!topVC) return;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"悬浮菜单"
                                                                   message:@"功能 1 待接入"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"功能 1（待实现）"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        NSLog(@"[FloatingMenu] 点击了功能 1");
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self;
    sheet.popoverPresentationController.sourceRect = self.bounds;
    [topVC presentViewController:sheet animated:YES completion:nil];
}

@end

__attribute__((constructor))
static void FloatingMenuInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            [FloatingMenuView showFloatingButton];
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [FloatingMenuView showFloatingButton];
        });
    });
}
