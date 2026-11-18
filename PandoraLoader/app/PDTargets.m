#import "PDTargets.h"
#import "PDStore.h"
#import "remote.h"
#include <libproc.h>
#include <unistd.h>

@implementation PDTarget
- (NSString *)description {
    return [NSString stringWithFormat:@"%@(%@) pid=%d", self.name, self.bundleId, self.pid];
}
@end

#pragma mark - 私有 API 调用

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"

static NSArray *pd_all_proxies(void) {
    Class ws = NSClassFromString(@"LSApplicationWorkspace");
    if (!ws) return @[];
    id workspace = [ws performSelector:@selector(defaultWorkspace)];
    if (!workspace) return @[];
    id apps = [workspace performSelector:@selector(allApplications)];
    return [apps isKindOfClass:[NSArray class]] ? apps : @[];
}

static id pd_proxy_call(id obj, NSString *sel, id fallback) {
    SEL s = NSSelectorFromString(sel);
    if (![obj respondsToSelector:s]) return fallback;
    id v = [obj performSelector:s];
    return v ?: fallback;
}

#pragma clang diagnostic pop

#pragma mark - 运行中的进程

/// bundlePath(小写) -> pid
static NSDictionary<NSString *, NSNumber *> *pd_running_map(void) {
    NSMutableDictionary *map = [NSMutableDictionary dictionary];

    int cap = 1024;
    pid_t *pids = malloc(sizeof(pid_t) * (size_t)cap);
    if (!pids) return map;

    int n = proc_listallpids(pids, sizeof(pid_t) * cap);
    if (n <= 0) { free(pids); return map; }

    for (int i = 0; i < n; i++) {
        char path[4096] = {0};
        if (proc_pidpath(pids[i], path, sizeof(path)) <= 0) continue;
        NSString *p = [NSString stringWithUTF8String:path];
        if (p.length == 0) continue;

        NSRange r = [p rangeOfString:@".app/"];
        if (r.location == NSNotFound) continue;
        NSString *bundle = [p substringToIndex:NSMaxRange(r) - 1];   /* 含 .app */

        /* 同一个 App 可能有多个进程（扩展），取主进程即可 */
        map[bundle.lowercaseString] = @(pids[i]);
    }
    free(pids);
    return map;
}

#pragma mark - 对外

@implementation PDTargets

+ (NSString *)payloadPath {
    NSString *p = [[NSBundle mainBundle] pathForResource:@"PandoraLoader" ofType:@"dylib"];
    if (!p) {
        /* 有些打包方式会把 dylib 放在根目录 */
        p = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"PandoraLoader.dylib"];
    }
    return [[NSFileManager defaultManager] fileExistsAtPath:p] ? p : nil;
}

+ (NSArray<PDTarget *> *)installedApps {
    NSDictionary *running = pd_running_map();
    NSMutableArray *out = [NSMutableArray array];

    for (id proxy in pd_all_proxies()) {
        NSString *bid = pd_proxy_call(proxy, @"bundleIdentifier", nil);
        if (![bid isKindOfClass:[NSString class]] || bid.length == 0) continue;

        NSURL *bundleURL = pd_proxy_call(proxy, @"bundleURL", nil);
        NSString *bundlePath = [bundleURL isKindOfClass:[NSURL class]] ? bundleURL.path : nil;
        if (bundlePath.length == 0) continue;

        /* 只要用户装的：/var/containers/Bundle/Application/... */
        if (![bundlePath containsString:@"/var/containers/Bundle/Application/"]) continue;

        NSString *name = pd_proxy_call(proxy, @"localizedName", nil);
        if (![name isKindOfClass:[NSString class]] || name.length == 0) name = bid;

        NSURL *dataURL = pd_proxy_call(proxy, @"dataContainerURL", nil);
        NSString *dataPath = [dataURL isKindOfClass:[NSURL class]] ? dataURL.path : @"";

        PDTarget *t = [PDTarget new];
        t.bundleId = bid;
        t.name = name;
        t.bundlePath = bundlePath;
        t.dataContainer = dataPath;

        NSNumber *pid = running[bundlePath.lowercaseString];
        t.running = (pid != nil);
        t.pid = pid ? pid.intValue : 0;

        [out addObject:t];
    }

    [out sortUsingComparator:^NSComparisonResult(PDTarget *a, PDTarget *b) {
        if (a.running != b.running) return a.running ? NSOrderedAscending : NSOrderedDescending;
        return [a.name localizedStandardCompare:b.name];
    }];

    return out;
}

#pragma mark - 静态注入配套

+ (NSString *)exportPayload:(NSString **)err {
    NSString *src = [self payloadPath];
    if (!src) {
        if (err) *err = @"App 包里没有 PandoraLoader.dylib";
        return nil;
    }
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dst = [docs stringByAppendingPathComponent:@"PandoraLoader.dylib"];
    [[NSFileManager defaultManager] removeItemAtPath:dst error:NULL];
    NSError *e = nil;
    if (![[NSFileManager defaultManager] copyItemAtPath:src toPath:dst error:&e]) {
        if (err) *err = e.localizedDescription ?: @"导出失败";
        return nil;
    }
    return dst;
}

+ (BOOL)syncScripts:(PDTarget *)target error:(NSString **)err {
    if (target.dataContainer.length < 2) {
        if (err) *err = @"拿不到目标的 dataContainer（App 可能已被卸载）";
        return NO;
    }

    NSString *dir = [target.dataContainer stringByAppendingPathComponent:@"Documents/Pandora/scripts"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *e = nil;
    if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&e]) {
        if (err) *err = [NSString stringWithFormat:@"在目标沙盒建目录失败：%@\n（容器 App 需要 platform-application 权限）",
                         e.localizedDescription ?: @"未知"];
        return NO;
    }

    NSArray<NSDictionary *> *files = [[PDStore shared] files];
    NSArray<NSString *> *pick = [[PDStore shared] selectionForBundle:target.bundleId];
    NSMutableArray *index = [NSMutableArray array];
    NSInteger written = 0;

    for (NSDictionary *f in files) {
        NSString *name = f[@"name"];
        if (pick && ![pick containsObject:name]) continue;   /* 这个 App 只绑定了一部分脚本 */
        NSData *d = [[PDStore shared] dataForName:name];
        if (!d) continue;
        if ([d writeToFile:[dir stringByAppendingPathComponent:name] atomically:YES]) {
            [index addObject:@{@"name": name, @"lang": f[@"lang"], @"size": @(d.length)}];
            written++;
        }
    }

    NSDictionary *man = @{@"ver": @([[PDStore shared] version]), @"files": index};
    NSData *md = [NSJSONSerialization dataWithJSONObject:man options:0 error:NULL];
    [md writeToFile:[dir stringByAppendingPathComponent:@"_manifest.json"] atomically:YES];

    /* 清掉已经删掉的脚本，避免目标侧还留着旧文件 */
    for (NSString *old in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
        if ([old isEqualToString:@"_manifest.json"]) continue;
        BOOL alive = NO;
        for (NSDictionary *f in files) if ([f[@"name"] isEqualToString:old]) { alive = YES; break; }
        if (!alive) [fm removeItemAtPath:[dir stringByAppendingPathComponent:old] error:NULL];
    }

    if (err) *err = [NSString stringWithFormat:@"已同步 %ld 个脚本 · v%lld",
                     (long)written, [[PDStore shared] version]];
    return YES;
}

+ (BOOL)prepare:(PDTarget *)target error:(NSString **)err {
    NSString *syncErr = nil;
    BOOL ok = [self syncScripts:target error:&syncErr];
    if (!ok) {
        if (err) *err = syncErr;
        return NO;
    }

    /* 顺手把 dylib 也放进去：attach 路线要用，静态路线不碍事 */
    NSString *src = [self payloadPath];
    if (src && target.dataContainer.length > 2) {
        NSString *dst = [target.dataContainer stringByAppendingPathComponent:@"Documents/PandoraLoader.dylib"];
        [[NSFileManager defaultManager] removeItemAtPath:dst error:NULL];
        [[NSFileManager defaultManager] copyItemAtPath:src toPath:dst error:NULL];
    }

    if (err) *err = syncErr;
    return YES;
}

+ (BOOL)inject:(PDTarget *)target error:(NSString **)err {
    if (!target || target.pid <= 0) {
        if (err) *err = @"目标没在运行，先把它启动起来";
        return NO;
    }

    NSString *prepErr = nil;
    [self prepare:target error:&prepErr];

    NSString *src = [self payloadPath];
    if (!src) {
        if (err) *err = @"App 包里没有 PandoraLoader.dylib，打包脚本没跑对";
        return NO;
    }

    /* 先探权限，失败信息比 dlopen 超时清楚得多 */
    char buf[1024] = {0};
    if (!pd_can_attach(target.pid, buf, sizeof(buf))) {
        if (err) *err = [NSString stringWithUTF8String:buf];
        return NO;
    }

    /* 关键：dylib 必须落在目标自己的容器里，否则 dlopen 被沙盒拒 */
    NSString *dst = nil;
    NSString *docDir = [target.dataContainer stringByAppendingPathComponent:@"Documents"];
    if (docDir.length > 2) {
        [[NSFileManager defaultManager] createDirectoryAtPath:docDir
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
        dst = [docDir stringByAppendingPathComponent:@"PandoraLoader.dylib"];
    } else {
        NSString *fallback = @"/var/mobile/Library/Pandora";
        [[NSFileManager defaultManager] createDirectoryAtPath:fallback
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
        dst = [fallback stringByAppendingPathComponent:@"PandoraLoader.dylib"];
    }

    NSError *copyErr = nil;
    [[NSFileManager defaultManager] removeItemAtPath:dst error:NULL];
    if (![[NSFileManager defaultManager] copyItemAtPath:src toPath:dst error:&copyErr]) {
        if (err) {
            *err = [NSString stringWithFormat:
                    @"把 dylib 拷进目标沙盒失败：%@\n"
                    @"（容器 App 需要 platform-application 权限；越狱环境基本都能写）",
                    copyErr.localizedDescription ?: @"未知"];
        }
        return NO;
    }

    char jerr[2048] = {0};
    if (!pd_inject_dylib(target.pid, dst.fileSystemRepresentation, jerr, sizeof(jerr))) {
        if (err) *err = [NSString stringWithUTF8String:jerr];
        return NO;
    }

    if (err) *err = [NSString stringWithFormat:@"已注入 pid %d", target.pid];
    return YES;
}

@end
