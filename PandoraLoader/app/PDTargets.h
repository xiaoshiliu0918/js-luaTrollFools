//
//  PDTargets.h —— 已安装 App 列表 + 注入
//
//  注入要解决两个现实问题：
//    1. 目标进程得有权限被 attach（task_for_pid）
//    2. dylib 得放在**目标自己的沙盒**里，否则 dlopen 时被 sandbox 拒
//  所以流程是：找到目标的 dataContainer → 把 dylib 拷进它的 Documents → dlopen 那个路径。
//

#ifndef PD_TARGETS_H
#define PD_TARGETS_H

#import <Foundation/Foundation.h>

@interface PDTarget : NSObject
@property (nonatomic) pid_t pid;                 // 0 = 没在跑
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *bundleId;
@property (nonatomic, copy) NSString *bundlePath;
@property (nonatomic, copy) NSString *dataContainer;
@property (nonatomic) BOOL running;
@end

@interface PDTargets : NSObject

/// 用户安装的 App（过滤掉系统 App）
+ (NSArray<PDTarget *> *)installedApps;

/// 只做准备：把 dylib 拷进目标容器 + 把脚本同步进容器（不需要目标在运行）
+ (BOOL)prepare:(PDTarget *)target error:(NSString **)err;

/// 同步脚本到 <目标容器>/Documents/Pandora/scripts（静态注入后靠它热更新）
+ (BOOL)syncScripts:(PDTarget *)target error:(NSString **)err;

/// 准备 + attach 注入（需要越狱；TrollStore-only 会失败）
+ (BOOL)inject:(PDTarget *)target error:(NSString **)err;

/// 把内置 dylib 导出到容器 App 的 Documents，方便 TrollFools 选它
+ (NSString *)exportPayload:(NSString **)err;

/// 内置 dylib 路径
+ (NSString *)payloadPath;

@end

#endif
