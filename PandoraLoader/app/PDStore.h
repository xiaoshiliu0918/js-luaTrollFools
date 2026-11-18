//
//  PDStore.h —— 容器 App 的脚本仓库
//
//  目录：<沙盒>/Documents/Scripts
//  版本号：所有脚本 mtime(秒)*1000 的最大值 + 文件数
//  —— 只要任何一个文件被改动（包括在别的 App 里用 Filza 改），版本号就会变，
//     注入端下一次轮询就会拉新版本，这就是热重载的触发点。
//

#ifndef PD_STORE_H
#define PD_STORE_H

#import <Foundation/Foundation.h>

@interface PDStore : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) NSString *dir;

/// 已排序：main.* 最前，然后 js、lua，同语言按名字。
/// 每项：@{@"name":..., @"lang":..., @"size":@(...), @"mtime":@(...)}
- (NSArray<NSDictionary *> *)files;

- (long long)version;

- (NSData *)dataForName:(NSString *)name;
- (BOOL)writeData:(NSData *)data name:(NSString *)name;
- (BOOL)deleteName:(NSString *)name;
- (BOOL)rename:(NSString *)from to:(NSString *)to;

/// 生成不冲突的文件名（导入重名时用）
- (NSString *)uniqueNameFor:(NSString *)name;

/// 首次启动写一份示例脚本
- (void)seedIfEmpty;

/// 某个 App 绑定的脚本（nil = 没设置，表示全部）
- (NSArray<NSString *> *)selectionForBundle:(NSString *)bundleId;
- (void)setSelection:(NSArray<NSString *> *)names forBundle:(NSString *)bundleId;

@end

#endif
