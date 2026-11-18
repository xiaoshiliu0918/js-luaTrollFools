//
//  PdClient.h —— 注入端主控
//
//  职责：连容器 App 的脚本服务器 → 拉 manifest → 拉文件 → 交给运行时执行
//        → 每帧 tick → 每秒比对版本号做热重载
//
//  所有对运行时的操作都在主线程（Unity 的线程），网络在后台队列。
//

#ifndef PD_CLIENT_H
#define PD_CLIENT_H

#import <Foundation/Foundation.h>

@interface PdClient : NSObject

+ (instancetype)shared;

- (void)start;
- (void)stop;

/// 跳过版本比对，立刻重拉一遍（Native.reload() 走这里）
- (void)forceReload;

/// 给上层看的一行状态，日志页会显示
@property (nonatomic, readonly) NSString *statusText;

@end

#endif
