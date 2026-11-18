//
//  PdEntry.mm —— dylib 入口
//
//  三种进法都走这里：
//    1) 容器 App 运行时 attach 注入（task_for_pid + 远程 dlopen）
//    2) TrollFools 之类的静态注入（改 Mach-O 的 LC_LOAD_DYLIB，重签后启动）
//    3) 越狱环境当 tweak 装（ElleKit/Substrate 按 bundle id 过滤）
//
//  共同点：都要等 App 起来再干活。构造函数里只登记，不做重活。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PdClient.h"
#import "PdLog.h"

/// 哪些进程不接管：没有 bundle id 的守护进程、SpringBoard、系统 App。
/// 要放行别的游戏，改这里，或者在 tweak 的 Filter 里限定。
static BOOL PdShouldActivate(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    if (bid.length == 0) return NO;
    if ([bid isEqualToString:@"com.apple.springboard"]) return NO;
    if ([bid hasPrefix:@"com.apple."]) return NO;
    if ([bid isEqualToString:@"com.pandora.loader"]) return NO;      /* 别注入容器 App 自己 */
    return YES;
}

static void PdStart(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[PdClient shared] start];
    });
}

__attribute__((constructor)) static void PdEntry(void) {
    @autoreleasepool {
        if (!PdShouldActivate()) return;

        /* 静态注入时构造函数跑在 UIApplicationMain 之前，
         * 那时 RunLoop 还没转起来，延迟到 UI 起来再拉脚本。 */
        if ([UIApplication sharedApplication] != nil) {
            PdStart();
        } else {
            [[NSNotificationCenter defaultCenter]
                addObserverForName:UIApplicationDidFinishLaunchingNotification
                            object:nil
                             queue:[NSOperationQueue mainQueue]
                        usingBlock:^(__unused NSNotification *note) { PdStart(); }];
        }
    }
}
