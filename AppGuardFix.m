#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <signal.h>
#include <execinfo.h>
#include <string.h>

// 1. 全局 UncaughtExceptionHandler：仅记录，返回后系统仍会终止进程
static void SafeUncaughtExceptionHandler(NSException *exception) {
    NSLog(@"[AppGuardFix] 捕获到未处理的 ObjC 异常: %@", exception);
    NSLog(@"[AppGuardFix] 原因: %@", [exception reason]);
    NSLog(@"[AppGuardFix] 异常调用栈: %@", [exception callStackSymbols]);
}

// 2. 信号拦截：记录现场后恢复默认处理并重新抛出
static struct sigaction g_prevActions[32];

static void SafeSignalHandler(int signal, siginfo_t *info, void *context) {
    NSLog(@"[AppGuardFix] 捕获到致命信号 Signal: %d, 发生地址: %p", signal, info->si_addr);

    void *callstack[128];
    int frames = backtrace(callstack, 128);
    char **strs = backtrace_symbols(callstack, frames);
    for (int i = 0; i < frames; ++i) {
        NSLog(@"[AppGuardFix] Frame %d: %s", i, strs[i]);
    }
    free(strs);

    // 恢复默认处理并重新抛出，避免无限重复触发同一故障指令
    if (signal > 0 && signal < 32) {
        sigaction(signal, &g_prevActions[signal], NULL);
    }
    raise(signal);
}

static void InstallSignalProtector(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = SafeSignalHandler;
    sa.sa_flags = SA_SIGINFO;

    int signals[] = {SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS};
    for (int i = 0; i < 5; i++) {
        int sig = signals[i];
        sigaction(sig, NULL, &g_prevActions[sig]);
        sigaction(sig, &sa, NULL);
    }

    struct sigaction ignore;
    memset(&ignore, 0, sizeof(ignore));
    ignore.sa_handler = SIG_IGN;
    sigaction(SIGPIPE, &ignore, NULL);
}

// 3. 构造函数：注入时自动初始化
__attribute__((constructor))
static void InitGuardEntry(void) {
    @autoreleasepool {
        NSLog(@"[AppGuardFix] >>> 修复与防御 Dylib 已成功挂载到目标进程 <<<");

        NSSetUncaughtExceptionHandler(&SafeUncaughtExceptionHandler);
        InstallSignalProtector();

        dispatch_async(dispatch_get_main_queue(), ^{
            NSLog(@"[AppGuardFix] 主线程心跳检测已就绪");
        });
    }
}
