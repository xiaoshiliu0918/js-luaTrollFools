//
//  PdRuntime.h —— 脚本运行时统一接口
//
//  目前两种：JavaScriptCore（系统自带，零成本）与 Lua 5.4（需要把源码放进 third_party/lua）。
//  上层（PdClient）只认这个协议，不关心底下是谁。
//

#ifndef PD_RUNTIME_H
#define PD_RUNTIME_H

#import <Foundation/Foundation.h>

/// 一个待执行的脚本文件
@interface PdScriptFile : NSObject
@property (nonatomic, copy)   NSString *name;    // "main.js"
@property (nonatomic, copy)   NSString *lang;    // "js" / "lua"
@property (nonatomic, strong) NSData   *data;
+ (instancetype)fileWithName:(NSString *)name lang:(NSString *)lang data:(NSData *)data;
@end

/// 运行时协议
@protocol PdRuntime <NSObject>
- (BOOL)loadFiles:(NSArray<PdScriptFile *> *)files error:(NSError **)error;
- (void)tickWithDelta:(double)dt;
- (void)unload;
@end

/// 工厂：lang = "js" 一定可用；"lua" 需要编译期带 Lua
@interface PdRuntimeFactory : NSObject
+ (id<PdRuntime>)runtimeForLang:(NSString *)lang error:(NSError **)error;
+ (BOOL)luaAvailable;
@end

#endif /* PD_RUNTIME_H */
