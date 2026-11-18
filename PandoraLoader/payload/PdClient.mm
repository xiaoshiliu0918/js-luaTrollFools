#import "PdClient.h"
#import "PdHttp.h"
#import "PdLog.h"
#import "PdRuntime.h"
#import "PdProtocol.h"
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

@interface PdClient ()
@property (nonatomic, strong) id<PdRuntime> runtime;
@property (nonatomic, copy)   NSString *currentVer;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, strong) NSTimer *poll;
@property (nonatomic, strong) NSMutableArray<NSString *> *logQueue;
@property (nonatomic, strong) NSLock *logLock;
@property (nonatomic) BOOL syncing;
@property (nonatomic) BOOL force;
@property (nonatomic) BOOL started;
@property (nonatomic) CFTimeInterval lastTick;
@property (nonatomic) NSTimeInterval frameInterval;
@property (nonatomic, copy) NSString *statusText;
@property (nonatomic, copy) NSString *tailPath;              // pjs 模式：跟踪游戏侧 js.log
@property (nonatomic) unsigned long long tailOffset;
@end

@implementation PdClient

+ (instancetype)shared {
    static PdClient *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [PdClient new]; });
    return c;
}

- (instancetype)init {
    if ((self = [super init])) {
        _logQueue = [NSMutableArray array];
        _logLock = [NSLock new];
        _frameInterval = 1.0 / 30.0;    /* 30fps 足够画 UI；脚本要更快就自己加 */
        _statusText = @"未启动";
    }
    return self;
}

#pragma mark - 生命周期

- (void)start {
    if (_started) return;
    _started = YES;

    PdLog(@"==== PandoraLoader 启动 · %@ · pid %d ====",
          [[NSBundle mainBundle] bundleIdentifier] ?: @"?", getpid());
    PdLog(@"脚本根目录: %@", PdRootDir());

    __weak PdClient *weakSelf = self;
    PdLogSetForwarder(^(NSString *line) { [weakSelf enqueueLog:line]; });

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onForceReload:)
                                                 name:@"PdForceReload"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];

    /* 先上缓存，再看容器 App 同步进来的脚本目录（静态注入时这是主通道） */
    [self loadCache];
    [self loadLocalBundle];

    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(onFrame:)];
    _link.preferredFramesPerSecond = 60;
    [_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

    _poll = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(onPoll:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_poll forMode:NSRunLoopCommonModes];

    [self sync];
}

- (void)stop {
    [_link invalidate]; _link = nil;
    [_poll invalidate]; _poll = nil;
    [self.runtime unload];
    self.runtime = nil;
    PdLogSetForwarder(nil);
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    _started = NO;
}

- (void)onForceReload:(__unused NSNotification *)note {
    [self forceReload];
}

- (void)onBecomeActive:(__unused NSNotification *)note {
    [self sync];
}

- (void)forceReload {
    _force = YES;
    PdLog(@"收到强制重载请求");
    [self sync];
}

#pragma mark - 帧循环

- (void)onFrame:(CADisplayLink *)link {
    if (!self.runtime) return;
    CFTimeInterval now = CACurrentMediaTime();
    double dt = now - _lastTick;
    if (dt < self.frameInterval) return;
    _lastTick = now;

    @autoreleasepool {
        @try {
            [self.runtime tickWithDelta:dt];
        } @catch (NSException *e) {
            PdLog(@"[tick] 运行时抛异常: %@", e.reason);
        }
    }
}

#pragma mark - 轮询 / 同步

- (void)onPoll:(NSTimer *)t {
    [self loadLocalBundle];
    [self tailPjsLog];
    [self flushLogs];
    [self sync];
}

/// pjs 模式下脚本的 console.log 落在游戏沙盒的 Pandora/js.log，
/// 这里把新增的部分读出来转发到容器 App —— PuerTS 里没有我们的原生通道。
- (void)tailPjsLog {
    if (self.tailPath.length == 0) return;

    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:self.tailPath error:NULL];
    unsigned long long size = [attr fileSize];
    if (size == 0) return;
    if (size < self.tailOffset) self.tailOffset = 0;      /* 被截断了 */
    if (size == self.tailOffset) return;

    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:self.tailPath];
    if (!fh) return;
    @try {
        [fh seekToFileOffset:self.tailOffset];
        NSData *d = [fh readDataToEndOfFile];
        self.tailOffset += d.length;
        NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        for (NSString *line in [s componentsSeparatedByString:@"\n"]) {
            if (line.length) [self enqueueLog:[@"[pjs] " stringByAppendingString:line]];
        }
    } @catch (__unused NSException *e) {
    } @finally {
        [fh closeFile];
    }
}

/// 网络在后台，应用在主线程
- (void)sync {
    if (_syncing) return;
    _syncing = YES;

    BOOL force = _force;
    _force = NO;
    NSString *knownVer = _currentVer ?: @"0";

    __weak PdClient *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        PdClient *self_ = weakSelf;
        if (!self_) return;

        NSString *err = nil;
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        NSString *path = [NSString stringWithFormat:@"/manifest?bid=%@&ver=%@&token=%s",
                          [bid stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
                          knownVer, PD_TOKEN];

        NSData *data = PdHttpGet(PD_PORT, path, 1.2, &err);
        if (!data) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self_->syncing = NO;
                if (!self_->runtime) self_->statusText = [NSString stringWithFormat:@"等容器 App（%@）", err ?: @"超时"];
                [self_ reportState:@"offline" msg:err ?: @"no-server"];
            });
            return;
        }

        NSError *jerr = nil;
        NSDictionary *man = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jerr];
        if (![man isKindOfClass:[NSDictionary class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self_->syncing = NO;
                PdLog(@"[sync] manifest 解析失败: %@", jerr);
            });
            return;
        }

        NSString *ver = [NSString stringWithFormat:@"%@", man[@"ver"] ?: @"0"];
        if (!force && [ver isEqualToString:knownVer] && self_->runtime) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self_->syncing = NO;
                self_->statusText = [NSString stringWithFormat:@"已连接 · v%@", ver];
                [self_ reportState:@"ok" msg:@""];
            });
            return;
        }

        /* 版本变了：把文件全拉下来 */
        NSArray *list = man[@"files"];
        if (![list isKindOfClass:[NSArray class]]) list = @[];

        NSMutableArray<PdScriptFile *> *files = [NSMutableArray array];
        for (NSDictionary *item in list) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSString *name = item[@"name"];
            NSString *lang = item[@"lang"] ?: @"js";
            if (![name isKindOfClass:[NSString class]] || name.length == 0) continue;
            if ([name containsString:@"/"] || [name containsString:@".."]) continue;  /* 路径穿越 */

            NSString *q = [name stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
            NSData *blob = PdHttpGet(PD_PORT, [NSString stringWithFormat:@"/file?name=%@", q], 2.5, NULL);
            if (!blob) {
                PdLog(@"[sync] 拉取 %@ 失败，放弃本次更新", name);
                files = nil;
                break;
            }
            [files addObject:[PdScriptFile fileWithName:name lang:lang data:blob]];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self_->syncing = NO;
            if (!files) return;
            [self_ applyFiles:files version:ver];
        });
    });
}

#pragma mark - 应用 / 卸载

- (void)applyFiles:(NSArray<PdScriptFile *> *)files version:(NSString *)ver {
    if (files.count == 0) {
        PdLog(@"[apply] 服务器上没有脚本，保持现状");
        return;
    }

    NSString *lang = files.firstObject.lang ?: @"js";
    NSError *err = nil;

    PdLog(@"[apply] 版本 v%@，%lu 个文件，语言 %@", ver, (unsigned long)files.count, lang);

    if (self.runtime) {
        @try { [self.runtime unload]; } @catch (__unused NSException *e) {}
        self.runtime = nil;
    }

    id<PdRuntime> rt = [PdRuntimeFactory runtimeForLang:lang error:&err];
    if (!rt) {
        PdLog(@"[apply] 起不来运行时: %@", err.localizedDescription);
        self.statusText = err.localizedDescription ?: @"运行时不可用";
        return;
    }

    if (![rt loadFiles:files error:&err]) {
        PdLog(@"[apply] 加载失败: %@", err.localizedDescription);
        self.statusText = err.localizedDescription ?: @"加载失败";
        return;
    }

    self.runtime = rt;
    self.currentVer = ver;
    self.tailPath = [lang isEqualToString:@"pjs"]
        ? [PdRootDir() stringByAppendingPathComponent:@"js.log"] : nil;
    self.tailOffset = 0;
    self.lastTick = CACurrentMediaTime();
    self.statusText = [NSString stringWithFormat:@"运行中 · v%@ · %lu 个文件", ver, (unsigned long)files.count];

    [self saveCache:files version:ver];
}

#pragma mark - 容器 App 同步过来的本地脚本

/// <沙盒>/Documents/Pandora/scripts/_manifest.json
/// 这条路不需要 socket：容器 App 把文件拷进目标沙盒后就退出也行。
- (void)loadLocalBundle {
    NSString *dir = [PdRootDir() stringByAppendingPathComponent:@"scripts"];
    NSString *manifestPath = [dir stringByAppendingPathComponent:@"_manifest.json"];

    NSData *md = [NSData dataWithContentsOfFile:manifestPath];
    if (!md) return;

    NSDictionary *man = [NSJSONSerialization JSONObjectWithData:md options:0 error:NULL];
    if (![man isKindOfClass:[NSDictionary class]]) return;

    NSString *ver = [NSString stringWithFormat:@"%@", man[@"ver"] ?: @"0"];
    if ([ver isEqualToString:self.currentVer ?: @""]) return;

    NSArray *list = man[@"files"];
    if (![list isKindOfClass:[NSArray class]] || list.count == 0) return;

    NSMutableArray<PdScriptFile *> *files = [NSMutableArray array];
    for (NSDictionary *item in list) {
        NSString *name = item[@"name"];
        if (![name isKindOfClass:[NSString class]] || [name containsString:@"/"]) continue;
        NSData *d = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:name]];
        if (d) [files addObject:[PdScriptFile fileWithName:name lang:item[@"lang"] ?: @"js" data:d]];
    }
    if (files.count == 0) return;

    PdLog(@"[local] 发现同步过来的新版本 v%@（%lu 个文件）", ver, (unsigned long)files.count);
    [self applyFiles:files version:ver];
}

#pragma mark - 缓存

- (NSString *)cacheDir {
    return [PdRootDir() stringByAppendingPathComponent:@"cache"];
}

- (void)saveCache:(NSArray<PdScriptFile *> *)files version:(NSString *)ver {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *dir = [[self cacheDir] stringByAppendingPathComponent:ver];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];

        NSMutableArray *index = [NSMutableArray array];
        for (PdScriptFile *f in files) {
            NSString *p = [dir stringByAppendingPathComponent:f.name];
            if ([f.data writeToFile:p atomically:YES]) {
                [index addObject:@{@"name": f.name, @"lang": f.lang, @"size": @(f.data.length)}];
            }
        }
        [index writeToFile:[dir stringByAppendingPathComponent:@"_index.json"] atomically:YES];

        /* 只留最近两个版本，别把目标 App 的沙盒塞满 */
        NSArray *all = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[self cacheDir] error:NULL];
        NSArray *sorted = [all sortedArrayUsingSelector:@selector(compare:)];
        if (sorted.count > 2) {
            for (NSUInteger i = 0; i + 2 < sorted.count; i++) {
                [[NSFileManager defaultManager] removeItemAtPath:[[self cacheDir] stringByAppendingPathComponent:sorted[i]]
                                                           error:NULL];
            }
        }
    });
}

- (void)loadCache {
    NSString *dir = [self cacheDir];
    NSArray *all = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL];
    if (all.count == 0) return;

    NSArray *sorted = [all sortedArrayUsingSelector:@selector(compare:)];
    NSString *ver = sorted.lastObject;
    NSString *vdir = [dir stringByAppendingPathComponent:ver];

    NSData *idxData = [NSData dataWithContentsOfFile:[vdir stringByAppendingPathComponent:@"_index.json"]];
    if (!idxData) return;
    NSArray *index = [NSJSONSerialization JSONObjectWithData:idxData options:0 error:NULL];
    if (![index isKindOfClass:[NSArray class]]) return;

    NSMutableArray<PdScriptFile *> *files = [NSMutableArray array];
    for (NSDictionary *item in index) {
        NSString *name = item[@"name"];
        if (![name isKindOfClass:[NSString class]]) continue;
        NSData *d = [NSData dataWithContentsOfFile:[vdir stringByAppendingPathComponent:name]];
        if (d) [files addObject:[PdScriptFile fileWithName:name lang:item[@"lang"] ?: @"js" data:d]];
    }
    if (files.count == 0) return;

    PdLog(@"[cache] 离线加载 v%@（%lu 个文件）", ver, (unsigned long)files.count);
    [self applyFiles:files version:ver];
}

#pragma mark - 日志回传

- (void)enqueueLog:(NSString *)line {
    [_logLock lock];
    if (_logQueue.count < 200) [_logQueue addObject:line];
    [_logLock unlock];
}

- (void)flushLogs {
    if (_logQueue.count == 0) return;

    [_logLock lock];
    NSString *joined = [_logQueue componentsJoinedByString:@"\n"];
    [_logQueue removeAllObjects];
    [_logLock unlock];

    NSString *q = [joined stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    if (q.length > 3500) q = [q substringToIndex:3500];   /* 单行太长就别推了 */

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        PdHttpGet(PD_PORT, [NSString stringWithFormat:@"/log?msg=%@", q], 0.8, NULL);
    });
}

- (void)reportState:(NSString *)state msg:(NSString *)msg {
    (void)state;
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    NSMutableString *path = [NSMutableString stringWithFormat:@"/state?bid=%@&ver=%@&pid=%d",
                             [bid stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
                             self.currentVer ?: @"0", getpid()];
    if (msg.length) {
        NSString *e = [msg stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
        [path appendFormat:@"&msg=%@", e];
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        PdHttpGet(PD_PORT, path, 0.6, NULL);
    });
}

@end
