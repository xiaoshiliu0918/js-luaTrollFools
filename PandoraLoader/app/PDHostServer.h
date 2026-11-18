//
//  PDHostServer.h —— 容器 App 侧的脚本服务器
//
//  只绑 127.0.0.1，端口 38999。注入端每秒来问一次版本号，
//  版本变了才重新拉文件 —— 所以平时的开销就是一个 200 字节的响应。
//

#ifndef PD_HOST_SERVER_H
#define PD_HOST_SERVER_H

#import <Foundation/Foundation.h>

@interface PDHostServer : NSObject

+ (instancetype)shared;

- (BOOL)startOnPort:(int)port error:(NSString **)err;
- (void)stop;

@property (nonatomic, readonly) BOOL running;
@property (nonatomic, readonly) int port;

/// 注入端推回来的日志
@property (nonatomic, copy) void (^logSink)(NSString *line);

/// 注入端心跳：@{@"bid":..., @"ver":..., @"pid":..., @"msg":..., @"time":...}
@property (nonatomic, copy) void (^stateSink)(NSDictionary *state);

/// 当前有哪些进程连过：bid -> 最近一次 state
- (NSArray<NSDictionary *> *)clients;

@end

#endif
