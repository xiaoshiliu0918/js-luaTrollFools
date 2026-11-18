#import "PDPatch.h"
#import "PDTools.h"
#import <signal.h>

@interface PDPatch ()
+ (NSString *)exePath:(PDTarget *)t;
+ (NSString *)backupPath:(PDTarget *)t;
+ (NSString *)stagedDylib:(PDTarget *)t;
+ (BOOL)isInjectedPath:(NSString *)exe;
+ (void)rollback:(PDTarget *)target log:(NSMutableString *)log;
@end

static NSString * const kDylibName = @"PandoraLoader.dylib";
static NSString * const kLoadPath  = @"@executable_path/Frameworks/PandoraLoader.dylib";

@implementation PDPatch

#pragma mark - 路径

+ (NSString *)exePath:(PDTarget *)t {
    NSString *plist = [t.bundlePath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plist];
    NSString *exe = info[@"CFBundleExecutable"];
    if (exe.length == 0) exe = t.bundlePath.lastPathComponent.stringByDeletingPathExtension;
    return [t.bundlePath stringByAppendingPathComponent:exe];
}

+ (NSString *)backupPath:(PDTarget *)t {
    return [[self exePath:t] stringByAppendingString:@".pandora.bak"];
}

+ (NSString *)stagedDylib:(PDTarget *)t {
    return [t.bundlePath stringByAppendingPathComponent:@"Frameworks/PandoraLoader.dylib"];
}

#pragma mark - 状态

+ (BOOL)isInjected:(PDTarget *)target {
    NSString *exe = [self exePath:target];
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:exe];
    if (!fh) return NO;
    NSData *head = [fh readDataOfLength:64 * 1024];   /* 加载命令都在头部 */
    [fh closeFile];

    NSData *needle = [kDylibName dataUsingEncoding:NSUTF8StringEncoding];
    return head.length && [head rangeOfData:needle options:0 range:NSMakeRange(0, head.length)].location != NSNotFound;
}

+ (BOOL)hasBackup:(PDTarget *)target {
    return [[NSFileManager defaultManager] fileExistsAtPath:[self backupPath:target]];
}

#pragma mark - 注入

+ (BOOL)inject:(PDTarget *)target error:(NSString **)err {
    NSMutableString *log = [NSMutableString string];

    if (![PDTools available]) {
        if (err) *err = [NSString stringWithFormat:
            @"工具链不全，缺：%@\n\n"
            @"这些工具在 TrollFools.app 里。两条路：\n"
            @"  · 装一个 TrollFools（TrollStore 里有）\n"
            @"  · 或者把 insert_dylib / ldid / ct_bypass / libiosexec.1.dylib 放进 Pandora.app/tools/",
            [PDTools missingTools]];
        return NO;
    }

    NSString *exe = [self exePath:target];
    if (![[NSFileManager defaultManager] fileExistsAtPath:exe]) {
        if (err) *err = [NSString stringWithFormat:@"找不到可执行文件：%@", exe];
        return NO;
    }

    NSString *payload = [PDTargets payloadPath];
    if (!payload) {
        if (err) *err = @"App 包里没有 PandoraLoader.dylib";
        return NO;
    }

    if ([self isInjected:target]) {
        /* 已经注入过：只刷新 dylib，别重复塞 LC */
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *dst = [self stagedDylib:target];
        [fm createDirectoryAtPath:[dst stringByDeletingLastPathComponent]
      withIntermediateDirectories:YES attributes:nil error:NULL];
        [fm removeItemAtPath:dst error:NULL];
        if (![fm copyItemAtPath:payload toPath:dst error:NULL]) {
            if (err) *err = @"刷新 dylib 失败";
            return NO;
        }
        [log appendString:@"已注入过，只刷新了 dylib\n"];

        NSString *out = nil;
        [PDTools run:@"ldid" args:@[@"-S", dst] output:&out error:&out];
        [log appendFormat:@"ldid -S dylib: %@\n", out.length ? out : @"ok"];

        /* 重签会换掉签名，必须重新打 CoreTrust 补丁，否则 App 启动闪退 */
        BOOL bp = [PDTools run:@"ct_bypass"
                          args:@[@"-a", @"-i", target.bundlePath, @"-r"]
                        output:&out error:&out];
        [log appendFormat:@"ct_bypass: %@\n", out.length ? out : @"ok"];

        if (!bp) {
            if (err) *err = [log stringByAppendingString:@"\nct_bypass 失败 —— 先别启动 App，用「还原」回退"];
            return NO;
        }

        if (err) *err = log;
        return YES;
    }

    /* ---------- 1. 备份（含原签名，回滚就靠它） ---------- */
    NSString *bak = [self backupPath:target];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:bak]) {
        NSError *e = nil;
        if (![fm copyItemAtPath:exe toPath:bak error:&e]) {
            if (err) *err = [NSString stringWithFormat:@"备份失败：%@", e.localizedDescription];
            return NO;
        }
    }
    [log appendFormat:@"备份 → %@\n", bak.lastPathComponent];

    /* ---------- 2. 先取原始 entitlements（改完就取不到了） ---------- */
    NSString *ent = [NSTemporaryDirectory() stringByAppendingPathComponent:@"pandora_ent.plist"];
    NSString *out = nil;
    [PDTools run:@"ldid" args:@[@"-e", exe] output:&out error:&out];
    if (out.length < 10) {
        [log appendString:@"ldid -e 没取到 entitlements，用空 plist 继续\n"];
        out = @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
               "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
               "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
               "<plist version=\"1.0\"><dict/></plist>\n";
    }
    [out writeToFile:ent atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [log appendString:@"已导出原 entitlements\n"];

    /* ---------- 3. 拷 dylib ---------- */
    NSString *dst = [self stagedDylib:target];
    [fm createDirectoryAtPath:[dst stringByDeletingLastPathComponent]
  withIntermediateDirectories:YES attributes:nil error:NULL];
    [fm removeItemAtPath:dst error:NULL];
    if (![fm copyItemAtPath:payload toPath:dst error:NULL]) {
        if (err) *err = [log stringByAppendingString:@"拷 dylib 进 Frameworks 失败"];
        return NO;
    }
    [log appendString:@"dylib → Frameworks/\n"];

    /* ---------- 4. 插 LC_LOAD_DYLIB ---------- */
    BOOL ok = [PDTools run:@"insert_dylib"
                      args:@[@"--inplace", @"--strip-codesig", @"--all-yes", kLoadPath, exe]
                    output:&out error:&out];
    [log appendFormat:@"insert_dylib: %@\n", out.length ? out : @"ok"];

    if (!ok || ![self isInjected:target]) {
        /* 换个姿势再试一次：输出到临时文件再覆盖 */
        NSString *tmp = [exe stringByAppendingString:@".pandora.new"];
        [fm removeItemAtPath:tmp error:NULL];
        [PDTools run:@"insert_dylib" args:@[kLoadPath, exe, tmp] output:&out error:&out];
        if ([fm fileExistsAtPath:tmp] && [self isInjectedPath:tmp]) {
            [fm removeItemAtPath:exe error:NULL];
            [fm moveItemAtPath:tmp toPath:exe error:NULL];
            ok = YES;
            [log appendString:@"insert_dylib 走了临时文件路径\n"];
        }
    }

    if (!ok || ![self isInjected:target]) {
        [self rollback:target log:log];
        if (err) *err = [log stringByAppendingString:@"\n插入 LC_LOAD_DYLIB 失败，已回滚"];
        return NO;
    }

    /* ---------- 5. 重签 + CoreTrust 补丁 ---------- */
    [PDTools run:@"ldid"
            args:@[[NSString stringWithFormat:@"-S%@", ent], exe]
          output:&out error:&out];
    [log appendFormat:@"ldid -S: %@\n", out.length ? out : @"ok"];

    [PDTools run:@"ldid" args:@[@"-S", dst] output:&out error:&out];
    [log appendFormat:@"ldid -S dylib: %@\n", out.length ? out : @"ok"];

    ok = [PDTools run:@"ct_bypass"
                 args:@[@"-a", @"-i", target.bundlePath, @"-r"]
               output:&out error:&out];
    [log appendFormat:@"ct_bypass: %@\n", out.length ? out : @"ok"];

    if (!ok) {
        [self rollback:target log:log];
        if (err) *err = [log stringByAppendingString:@"\nct_bypass 失败，已回滚（App 不会变砖）"];
        return NO;
    }

    [log appendString:@"\n完成。启动目标 App 即生效。"];

    /* 目标还开着就杀掉，否则它跑的还是旧镜像 */
    if (target.pid > 0) kill(target.pid, SIGKILL);

    if (err) *err = log;
    return YES;
}

/// 只读文件头判断注入标记（不依赖 target 状态）
+ (BOOL)isInjectedPath:(NSString *)exe {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:exe];
    if (!fh) return NO;
    NSData *head = [fh readDataOfLength:64 * 1024];
    [fh closeFile];
    NSData *needle = [kDylibName dataUsingEncoding:NSUTF8StringEncoding];
    return head.length && [head rangeOfData:needle options:0 range:NSMakeRange(0, head.length)].location != NSNotFound;
}

+ (void)rollback:(PDTarget *)target log:(NSMutableString *)log {
    NSString *bak = [self backupPath:target];
    NSString *exe = [self exePath:target];
    NSFileManager *fm = [NSFileManager defaultManager];

    if ([fm fileExistsAtPath:bak]) {
        [fm removeItemAtPath:exe error:NULL];
        if ([fm copyItemAtPath:bak toPath:exe error:NULL]) {
            [log appendString:@"已从备份还原可执行文件\n"];
        } else {
            [log appendString:@"!! 还原失败，备份还在："];
            [log appendString:bak];
            [log appendString:@"\n"];
        }
    }
    [fm removeItemAtPath:[self stagedDylib:target] error:NULL];
}

#pragma mark - 还原

+ (BOOL)restore:(PDTarget *)target error:(NSString **)err {
    NSString *bak = [self backupPath:target];
    NSString *exe = [self exePath:target];
    NSFileManager *fm = [NSFileManager defaultManager];

    if (![fm fileExistsAtPath:bak]) {
        if (err) *err = @"没有备份，无法还原（可能不是本工具注入的）";
        return NO;
    }

    [fm removeItemAtPath:exe error:NULL];
    NSError *e = nil;
    if (![fm copyItemAtPath:bak toPath:exe error:&e]) {
        if (err) *err = [NSString stringWithFormat:@"还原失败：%@", e.localizedDescription];
        return NO;
    }
    [fm removeItemAtPath:[self stagedDylib:target] error:NULL];

    /* 备份本身带原签名，盖回去就是原始状态 */
    if (err) *err = @"已还原到注入前（原始字节 + 原签名）";
    return YES;
}

@end
