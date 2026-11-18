//
//  PDPatch.h —— 在容器 App 内完成「静态注入」
//
//  这是 TrollFools 的核心动作，拆开就四步：
//    1. 备份原始可执行文件（回滚用，必须最先做）
//    2. 把 dylib 拷进 Target.app/Frameworks/
//    3. insert_dylib 往 Mach-O 里塞一条 LC_LOAD_DYLIB
//    4. ldid 重签 + ct_bypass 打 CoreTrust 补丁（不打这个，改过的 App 启动就闪退）
//
//  任何一步失败都会回滚到备份 —— 备份是原始字节（含原签名），
//  盖回去就能恢复原状，不会把 App 弄成打不开的砖。
//

#ifndef PD_PATCH_H
#define PD_PATCH_H

#import <Foundation/Foundation.h>
#import "PDTargets.h"

@interface PDPatch : NSObject

/// 目标可执行文件里是否已经有我们的 LC_LOAD_DYLIB
+ (BOOL)isInjected:(PDTarget *)target;

/// 备份是否存在（说明做过注入，可以还原）
+ (BOOL)hasBackup:(PDTarget *)target;

/// 注入。成功返回 YES，err 里是过程日志
+ (BOOL)inject:(PDTarget *)target error:(NSString **)err;

/// 还原到注入前
+ (BOOL)restore:(PDTarget *)target error:(NSString **)err;

@end

#endif
