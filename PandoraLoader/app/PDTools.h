//
//  PDTools.h —— 借用已安装 TrollFools 的工具链
//
//  为什么不自己打包 insert_dylib / ldid / ct_bypass：
//    · 它们是 arm64 可执行文件，塞进 tipa 会有签名与许可证问题
//    · TrollFools 已经装在机器上，路径稳定，直接借来跑最省事
//    · 真要自带，把 tools/ 目录放进 Pandora.app 即可，PDTools 会优先用自带的
//
//  为什么要 libiosexec：
//    iOS 应用默认不能 exec 自己的二进制（沙盒 + AMFI）。libiosexec 导出
//    ie_posix_spawn，用它代替 posix_spawn 才能跑起来。TrollFools 就是这么干的。
//

#ifndef PD_TOOLS_H
#define PD_TOOLS_H

#import <Foundation/Foundation.h>

@interface PDTools : NSObject

/// TrollFools.app 的路径；没装返回 nil
+ (NSString *)trollFoolsBundle;

/// 找一个工具（insert_dylib / ldid / ct_bypass / libiosexec.1.dylib）
/// 先找 Pandora.app/tools/，再找 TrollFools.app/
+ (NSString *)toolPath:(NSString *)name;

/// 工具是否齐全
+ (BOOL)available;
+ (NSString *)missingTools;

/// 跑一个工具，捕获 stdout+stderr。成功返回 YES（不看退出码，看 error 里的输出）
+ (BOOL)run:(NSString *)tool
       args:(NSArray<NSString *> *)args
     output:(NSString **)output
      error:(NSString **)error;

@end

#endif
