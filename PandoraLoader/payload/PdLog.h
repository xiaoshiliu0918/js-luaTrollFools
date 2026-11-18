//
//  PdLog.h —— 注入端日志
//
//  两个去处：
//    1) 目标 App 沙盒内 Documents/Pandora/pandora.log（脱机也留痕）
//    2) 通过回环 socket 推回容器 App 的日志页（App 在后台时可能失败，失败就算了）
//
//  绝对不能因为日志把宿主搞崩：所有写入都在 @try 里，失败静默。
//

#ifndef PD_LOG_H
#define PD_LOG_H

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 日志文件路径（首次调用时创建目录）
NSString *PdLogPath(void);

/// 注入端根目录：<沙盒>/Documents/Pandora
NSString *PdRootDir(void);

/// 打印一行日志。支持 printf 风格，自动加时间戳与线程标记。
void PdLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

/// 由 PdClient 注入：把日志同时推给容器 App。传 nil 取消。
void PdLogSetForwarder(void (^forwarder)(NSString *line));

/// 只写文件、不推 socket（内部用，避免递归）
void PdLogLocal(NSString *line);

#ifdef __cplusplus
}
#endif

#endif /* PD_LOG_H */
