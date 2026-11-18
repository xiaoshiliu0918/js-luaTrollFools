#import "PdRuntime.h"
#import "PdLog.h"
#import "PdPrelude.h"
#import <JavaScriptCore/JavaScriptCore.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach_time.h>

#pragma mark - 文件模型

@implementation PdScriptFile
+ (instancetype)fileWithName:(NSString *)name lang:(NSString *)lang data:(NSData *)data {
    PdScriptFile *f = [PdScriptFile new];
    f.name = name;
    f.lang = lang;
    f.data = data;
    return f;
}
@end

#pragma mark - JSC 执行时间上限（私有 API，拿不到就退化成不限制）

typedef bool (*PdJSLimitCallback)(void *);
typedef bool (*PdSetLimitFn)(JSContextGroupRef, double, PdJSLimitCallback, void *);

static PdSetLimitFn pd_lookup_set_limit(void) {
    static PdSetLimitFn fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", RTLD_NOW);
        if (h) {
            fn = (PdSetLimitFn)dlsym(h, "JSContextGroupSetExecutionTimeLimit");
        }
    });
    return fn;
}

static bool pd_js_limit_hit(void *ctxPtr) {
    PdLog(@"[js] 单次执行超过时间上限，已中断（大概率是死循环）");
    return true;   /* true = 继续等一会儿；false = 立刻抛 TerminatedExecution */
}

#pragma mark - JS 运行时

@interface PdJSRuntime : NSObject <PdRuntime>
@property (nonatomic, strong) JSContext *ctx;
@end

@implementation PdJSRuntime

- (instancetype)init {
    if ((self = [super init])) {
        _ctx = [[JSContext alloc] init];
        __weak PdJSRuntime *weakSelf = self;
        _ctx.exceptionHandler = ^(JSContext *c, JSValue *e) {
            (void)weakSelf;
            PdLog(@"[js] 未捕获异常: %@", [e toString]);
        };
        [self installHost];
    }
    return self;
}

/// 暴露给 prelude.js 的原生函数。刻意只给最小集合，其余全在 JS 里实现。
- (void)installHost {
    JSContext *js = _ctx;

    js[@"__pd_log"] = ^(JSValue *v) {
        PdLog(@"[js] %@", [v toString]);
    };

    js[@"__pd_info"] = ^JSValue *{
        JSValue *o = [JSValue valueWithNewObjectInContext:js];
        o[@"bid"]  = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        o[@"pid"]  = @(getpid());
        o[@"root"] = PdRootDir();
        o[@"ios"]  = [[UIDevice currentDevice] systemVersion] ?: @"";
        return o;
    };

    js[@"__pd_reload"] = ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"PdForceReload" object:nil];
    };

    js[@"__pd_read"] = ^NSString *(JSValue *path) {
        NSString *p = [path toString];
        if (![p hasPrefix:@"/"]) p = [PdRootDir() stringByAppendingPathComponent:p];
        return [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:NULL] ?: @"";
    };

    js[@"__pd_write"] = ^BOOL(JSValue *path, JSValue *text) {
        NSString *p = [path toString];
        if (![p hasPrefix:@"/"]) p = [PdRootDir() stringByAppendingPathComponent:p];
        [[NSFileManager defaultManager] createDirectoryAtPath:[p stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES attributes:nil error:NULL];
        return [[text toString] writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    };

    /* 单次执行 3 秒上限，防止脚本死循环把游戏卡死 */
    PdSetLimitFn setLimit = pd_lookup_set_limit();
    if (setLimit) {
        setLimit(JSContextGetGroup(js.JSGlobalContextRef), 3.0, pd_js_limit_hit, NULL);
    } else {
        PdLog(@"[js] JSContextGroupSetExecutionTimeLimit 不可用，脚本死循环不会被打断");
    }
}

- (BOOL)loadFiles:(NSArray<PdScriptFile *> *)files error:(NSError **)error {
    /* prelude 先跑：console / 定时器 / onTick / Native 都在里面 */
    NSString *prelude = [[NSBundle mainBundle] pathForResource:@"prelude" ofType:@"js"];
    NSString *preludeSrc = prelude ? [NSString stringWithContentsOfFile:prelude encoding:NSUTF8StringEncoding error:NULL] : nil;
    if (preludeSrc.length == 0) {
        preludeSrc = [NSString stringWithUTF8String:(const char *)g_pd_prelude_js];
    }
    if (preludeSrc.length == 0) {
        if (error) *error = [NSError errorWithDomain:@"pandora" code:1 userInfo:@{NSLocalizedDescriptionKey: @"prelude.js 缺失"}];
        return NO;
    }

    [_ctx evaluateScript:preludeSrc withSourceURL:[NSURL URLWithString:@"pandora://prelude.js"]];

    for (PdScriptFile *f in files) {
        NSString *src = [[NSString alloc] initWithData:f.data encoding:NSUTF8StringEncoding];
        if (!src) {
            PdLog(@"[js] %@ 不是合法 UTF-8，跳过", f.name);
            continue;
        }
        NSString *url = [@"pandora://" stringByAppendingString:f.name];
        JSValue *ret = [_ctx evaluateScript:src withSourceURL:[NSURL URLWithString:url]];
        if (ret == nil && _ctx.exception) {
            PdLog(@"[js] %@ 执行失败: %@", f.name, [_ctx.exception toString]);
        } else {
            PdLog(@"[js] %@ 已加载 (%lu 字节)", f.name, (unsigned long)f.data.length);
        }
    }
    return YES;
}

- (void)tickWithDelta:(double)dt {
    JSValue *fn = _ctx[@"__pd_tick"];
    if (!fn || fn.isUndefined || fn.isNull) return;
    @try {
        [fn callWithArguments:@[@(dt), @([[NSDate date] timeIntervalSince1970] * 1000.0)]];
    } @catch (NSException *e) {
        PdLog(@"[js] tick 抛异常: %@", e.reason);
    }
}

- (void)unload {
    @try {
        JSValue *fn = _ctx[@"__pd_unload"];
        if (fn && !fn.isUndefined) [fn callWithArguments:@[]];
    } @catch (__unused NSException *e) {}
    _ctx = nil;   /* 释放整个 VM，脚本留下的对象由 JSC 回收 */
}

@end

#pragma mark - 工厂

@implementation PdRuntimeFactory

+ (BOOL)luaAvailable {
#if __has_include("lua.h")
    return YES;
#else
    return NO;
#endif
}

+ (id<PdRuntime>)runtimeForLang:(NSString *)lang error:(NSError **)error {
    if ([lang isEqualToString:@"js"] || [lang isEqualToString:@"javascript"]) {
        return [PdJSRuntime new];
    }
    if ([lang isEqualToString:@"pjs"]) {
        /* 跑在游戏自己的 PuerTS 里：白拿 CS.*，但需要游戏内置 JsEnvManager */
        Class c = NSClassFromString(@"PdPandoraRuntime");
        if (c) return [[c alloc] init];
        if (error) {
            *error = [NSError errorWithDomain:@"pandora" code:5 userInfo:@{
                NSLocalizedDescriptionKey: @"pjs 运行时没有注册（PdPandora.mm 没编进来）"
            }];
        }
        return nil;
    }
    if ([lang isEqualToString:@"lua"]) {
#if __has_include("lua.h")
        Class c = NSClassFromString(@"PdLuaRuntime");
        if (c) return [[c alloc] init];
#else
        if (error) {
            *error = [NSError errorWithDomain:@"pandora" code:2 userInfo:@{
                NSLocalizedDescriptionKey: @"这个包没有内置 Lua 引擎（third_party/lua 为空），只能用 .js"
            }];
        }
        return nil;
#endif
    }
    if (error) {
        *error = [NSError errorWithDomain:@"pandora" code:3 userInfo:@{
            NSLocalizedDescriptionKey: [NSString stringWithFormat:@"不认识的脚本类型: %@", lang]
        }];
    }
    return nil;
}

@end
