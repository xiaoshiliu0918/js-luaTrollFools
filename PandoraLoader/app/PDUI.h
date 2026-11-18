#ifndef PD_UI_H
#define PD_UI_H

#import <UIKit/UIKit.h>

@interface PDAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

/// 全局日志（容器 App 自己的日志 + 注入端推回来的日志）
@interface PDLogCenter : NSObject
+ (instancetype)shared;
- (void)add:(NSString *)line;
@property (nonatomic, readonly, copy) NSString *text;
@end

#endif
