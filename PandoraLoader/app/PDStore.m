#import "PDStore.h"
#import <sys/stat.h>

@implementation PDStore

+ (instancetype)shared {
    static PDStore *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [PDStore new]; });
    return s;
}

- (NSString *)dir {
    static NSString *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        d = [docs stringByAppendingPathComponent:@"Scripts"];
        [[NSFileManager defaultManager] createDirectoryAtPath:d
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
    });
    return d;
}

- (NSString *)langForName:(NSString *)name {
    NSString *ext = name.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"lua"]) return @"lua";
    if ([ext isEqualToString:@"pjs"]) return @"pjs";   /* 跑在游戏自己的 PuerTS 里 */
    return @"js";
}

- (NSArray<NSDictionary *> *)files {
    NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.dir error:NULL];
    NSMutableArray *out = [NSMutableArray array];

    for (NSString *name in names) {
        if ([name hasPrefix:@"."]) continue;
        NSString *ext = name.pathExtension.lowercaseString;
        if (![ext isEqualToString:@"js"] && ![ext isEqualToString:@"lua"] && ![ext isEqualToString:@"pjs"]) continue;

        NSString *full = [self.dir stringByAppendingPathComponent:name];
        struct stat st;
        if (stat(full.fileSystemRepresentation, &st) != 0) continue;

        [out addObject:@{
            @"name": name,
            @"lang": [self langForName:name],
            @"size": @(st.st_size),
            @"mtime": @((long long)st.st_mtimespec.tv_sec)
        }];
    }

    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSString *na = a[@"name"], *nb = b[@"name"];
        BOOL ma = [na.stringByDeletingPathExtension.lowercaseString isEqualToString:@"main"];
        BOOL mb = [nb.stringByDeletingPathExtension.lowercaseString isEqualToString:@"main"];
        if (ma != mb) return ma ? NSOrderedAscending : NSOrderedDescending;

        BOOL la = [a[@"lang"] isEqualToString:@"js"], lb = [b[@"lang"] isEqualToString:@"js"];
        if (la != lb) return la ? NSOrderedAscending : NSOrderedDescending;   /* 先 js 后 lua */

        return [na localizedStandardCompare:nb];
    }];

    return out;
}

- (long long)version {
    long long maxM = 0;
    NSInteger n = 0;
    for (NSDictionary *f in [self files]) {
        long long m = [f[@"mtime"] longLongValue];
        if (m > maxM) maxM = m;
        n++;
    }
    return maxM * 1000 + n;
}

- (NSData *)dataForName:(NSString *)name {
    if (name.length == 0 || [name containsString:@"/"] || [name containsString:@".."]) return nil;
    return [NSData dataWithContentsOfFile:[self.dir stringByAppendingPathComponent:name]];
}

- (BOOL)writeData:(NSData *)data name:(NSString *)name {
    if (name.length == 0 || [name containsString:@"/"] || [name containsString:@".."]) return NO;
    return [data writeToFile:[self.dir stringByAppendingPathComponent:name] atomically:YES];
}

- (BOOL)deleteName:(NSString *)name {
    if (name.length == 0 || [name containsString:@"/"] || [name containsString:@".."]) return NO;
    return [[NSFileManager defaultManager] removeItemAtPath:[self.dir stringByAppendingPathComponent:name] error:NULL];
}

- (BOOL)rename:(NSString *)from to:(NSString *)to {
    if (from.length == 0 || to.length == 0) return NO;
    if ([to containsString:@"/"] || [to containsString:@".."]) return NO;
    return [[NSFileManager defaultManager] moveItemAtPath:[self.dir stringByAppendingPathComponent:from]
                                                   toPath:[self.dir stringByAppendingPathComponent:to]
                                                    error:NULL];
}

- (NSString *)uniqueNameFor:(NSString *)name {
    NSString *base = name.stringByDeletingPathExtension;
    NSString *ext = name.pathExtension;
    NSString *candidate = name;
    int i = 2;
    while ([[NSFileManager defaultManager] fileExistsAtPath:[self.dir stringByAppendingPathComponent:candidate]]) {
        candidate = [NSString stringWithFormat:@"%@-%d.%@", base, i++, ext];
        if (i > 999) break;
    }
    return candidate;
}

#pragma mark - 每个 App 的脚本绑定

- (NSString *)bindingsPath {
    return [self.dir.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"Bindings.plist"];
}

- (NSDictionary *)bindings {
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[self bindingsPath]];
    return [d isKindOfClass:[NSDictionary class]] ? d : @{};
}

- (NSArray<NSString *> *)selectionForBundle:(NSString *)bundleId {
    if (bundleId.length == 0) return nil;
    id v = [self bindings][bundleId];
    return [v isKindOfClass:[NSArray class]] ? v : nil;
}

- (void)setSelection:(NSArray<NSString *> *)names forBundle:(NSString *)bundleId {
    if (bundleId.length == 0) return;
    NSMutableDictionary *d = [[self bindings] mutableCopy];
    if (names.count == 0) [d removeObjectForKey:bundleId];
    else d[bundleId] = names;
    [d writeToFile:[self bindingsPath] atomically:YES];
}

- (void)seedIfEmpty {
    if ([self files].count > 0) return;

    NSString *js =
    @"// 示例脚本：改完点右上角刷新，游戏里 1 秒内生效（不用重启）\n"
    @"console.log('hello from ' + Native.info.bid);\n"
    @"\n"
    @"var frames = 0;\n"
    @"onTick(function (dt) {\n"
    @"  frames++;\n"
    @"  if (frames % 300 === 0) console.log('tick ' + frames + ' dt=' + dt.toFixed(3));\n"
    @"});\n"
    @"\n"
    @"onUnload(function () { console.log('bye'); });\n";

    [self writeData:[js dataUsingEncoding:NSUTF8StringEncoding] name:@"main.js"];
}

@end
