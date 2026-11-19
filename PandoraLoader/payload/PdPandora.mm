//
//  PdPandora.mm —— 「跑在游戏自己的 JS 虚拟机里」
//
//  跟 PdJS.mm 的区别：
//    PdJS      ：我们自己建一个 JavaScriptCore，脚本与世隔绝，没有 CS.*
//    PdPandora ：找到游戏的 com.tencent.pandora.JsEnvManager，调它的
//                GetJsEnv() → Eval(js, chunkName)，直接进游戏现成的 PuerTS VM
//
//  后者的好处是白拿一整套 CS.UnityEngine / CS.SGW / 反射桥 —— 因为那本来就是
//  游戏自己的运行时。绘制.js 这种脚本只有在这条路上才跑得起来。
//
//  代价：
//    · 前提是游戏真的内置 PuerTS（王者 S45 有，JsEnvManager 在 Scripts.Plugins.dll）
//    · 脚本和游戏共享一个 VM，抛异常会影响同一个 JS 上下文，必须自己 try/catch
//    · 没法真正「卸载」：重载就是再 Eval 一次，旧脚本的定时器/画布要脚本自己清理
//
//  日志走文件：PuerTS 里没有我们的 console，只能 CS.System.IO.File.AppendAllText，
//  再由 PdClient 尾部跟踪这个文件、转发到容器 App 的日志页。
//

#import "PdRuntime.h"
#import "PdLog.h"

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <string.h>
#import <unistd.h>

// ---------------------------------------------------------------- il2cpp 符号

typedef void *(*pd_domain_get_t)(void);
typedef void *(*pd_domain_asm_t)(void *, size_t *);
typedef void *(*pd_asm_image_t)(void *);
typedef void *(*pd_class_from_name_t)(void *, const char *, const char *);
typedef void *(*pd_method_from_name_t)(void *, const char *, int);
typedef void *(*pd_invoke_t)(void *, void *, void **, void **);
typedef void *(*pd_string_new_t)(const char *);
typedef void *(*pd_thread_attach_t)(void *);
typedef void *(*pd_class_methods_t)(void *, void **);
typedef const char *(*pd_method_name_t)(void *);
typedef uint32_t (*pd_method_nargs_t)(void *);
typedef bool (*pd_method_generic_t)(void *);

static struct {
    void *handle;
    pd_domain_get_t        domain_get;
    pd_domain_asm_t        domain_asm;
    pd_asm_image_t         asm_image;
    pd_class_from_name_t   class_from_name;
    pd_method_from_name_t  method_from_name;
    pd_invoke_t            invoke;
    pd_string_new_t        string_new;
    pd_thread_attach_t     thread_attach;
    pd_class_methods_t     class_methods;
    pd_method_name_t       method_name;
    pd_method_nargs_t      method_nargs;
    pd_method_generic_t    method_generic;
    BOOL                   ready;
} g_il2;

static NSString *pd_il2_load(void) {
    if (g_il2.ready) return nil;

    /* 静态注入时 UnityFramework 已经加载，符号是全局的；先试默认句柄 */
    void *h = dlopen(NULL, RTLD_LAZY | RTLD_GLOBAL);
    if (!h || !dlsym(h, "il2cpp_domain_get")) {
        const char *paths[] = {
            "Frameworks/UnityFramework.framework/UnityFramework",
            "@rpath/UnityFramework.framework/UnityFramework",
        };
        h = NULL;
        for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]) && !h; i++) {
            void *cand = dlopen(paths[i], RTLD_LAZY | RTLD_GLOBAL);
            if (cand && dlsym(cand, "il2cpp_domain_get")) h = cand;
        }
    }
    if (!h) return @"拿不到 il2cpp 符号（没找到 UnityFramework）";

    struct { void **dst; const char *name; } tbl[] = {
        { (void **)&g_il2.domain_get,      "il2cpp_domain_get" },
        { (void **)&g_il2.domain_asm,      "il2cpp_domain_get_assemblies" },
        { (void **)&g_il2.asm_image,       "il2cpp_assembly_get_image" },
        { (void **)&g_il2.class_from_name, "il2cpp_class_from_name" },
        { (void **)&g_il2.method_from_name,"il2cpp_class_get_method_from_name" },
        { (void **)&g_il2.invoke,          "il2cpp_runtime_invoke" },
        { (void **)&g_il2.string_new,      "il2cpp_string_new" },
        { (void **)&g_il2.thread_attach,   "il2cpp_thread_attach" },
    };
    for (size_t i = 0; i < sizeof(tbl) / sizeof(tbl[0]); i++) {
        *tbl[i].dst = dlsym(h, tbl[i].name);
        if (!*tbl[i].dst) {
            return [NSString stringWithFormat:@"UnityFramework 缺符号 %s", tbl[i].name];
        }
    }

    /* 下面这几个是可选的：没有也能跑，只是挑 Eval 重载时更笨一点 */
    g_il2.class_methods  = (pd_class_methods_t)dlsym(h, "il2cpp_class_get_methods");
    g_il2.method_name    = (pd_method_name_t)dlsym(h, "il2cpp_method_get_name");
    g_il2.method_nargs   = (pd_method_nargs_t)dlsym(h, "il2cpp_method_get_param_count");
    g_il2.method_generic = (pd_method_generic_t)dlsym(h, "il2cpp_method_is_generic");

    g_il2.handle = h;
    g_il2.ready = YES;
    return nil;
}

/// 不按镜像名猜：JsEnvManager 在 Scripts.Plugins.dll 里，镜像名不含 pandora
static void *pd_find_class_any_image(void *domain, const char *ns, const char *name) {
    size_t n = 0;
    void **asms = (void **)g_il2.domain_asm(domain, &n);
    for (size_t i = 0; asms && i < n; i++) {
        void *img = g_il2.asm_image(asms[i]);
        if (!img) continue;
        void *cls = g_il2.class_from_name(img, ns, name);
        if (cls) return cls;
    }
    return NULL;
}

/// JsEnv 上有两个 Eval（一个泛型一个非泛型），必须挑非泛型那个
static void *pd_pick_eval(void *envCls) {
    if (g_il2.class_methods && g_il2.method_name && g_il2.method_nargs) {
        void *iter = NULL, *m = NULL;
        int guard = 0;
        while (guard++ < 512 && (m = g_il2.class_methods(envCls, &iter)) != NULL) {
            const char *nm = g_il2.method_name(m);
            if (!nm || strcmp(nm, "Eval") != 0) continue;
            if (g_il2.method_nargs(m) != 2) continue;
            if (g_il2.method_generic && g_il2.method_generic(m)) continue;
            return m;
        }
    }
    return g_il2.method_from_name(envCls, "Eval", 2);
}

// ---------------------------------------------------------------- 运行时

static NSString *pd_js_quote(NSString *s) {
    NSMutableString *r = [s mutableCopy];
    [r replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:0 range:NSMakeRange(0, r.length)];
    [r replaceOccurrencesOfString:@"'" withString:@"\\'" options:0 range:NSMakeRange(0, r.length)];
    [r replaceOccurrencesOfString:@"\n" withString:@"\\n" options:0 range:NSMakeRange(0, r.length)];
    [r replaceOccurrencesOfString:@"\r" withString:@"" options:0 range:NSMakeRange(0, r.length)];
    return r;
}

/// 注入到 PuerTS 里的前置脚本：console / onTick / onUnload / Native
static NSString *pd_pjs_prelude(NSString *logPath) {
    NSString *log = pd_js_quote(logPath);
    NSString *bid = pd_js_quote([[NSBundle mainBundle] bundleIdentifier] ?: @"");
    NSString *root = pd_js_quote(PdRootDir());

    return [NSString stringWithFormat:
        @"(function(g){\n"
        @"  if(g.__pd_interval&&typeof clearInterval==='function'){ try{clearInterval(g.__pd_interval);}catch(e){} g.__pd_interval=0; }\n"
        @"  if(typeof g.__pd_unload==='function'){ try{g.__pd_unload();}catch(e){} }\n"
        @"  var LOG='%@', BID='%@', ROOT='%@';\n"
        @"  function w(s){ try{ CS.System.IO.File.AppendAllText(LOG, s+'\\n'); }catch(e){} }\n"
        @"  function fmt(v){ try{ return typeof v==='string'?v:JSON.stringify(v); }catch(e){ return String(v); } }\n"
        @"  g.console={ log:function(){ var a=[]; for(var i=0;i<arguments.length;i++)a.push(fmt(arguments[i])); w(a.join(' ')); } };\n"
        @"  g.console.info=g.console.log; g.console.warn=function(){ w('[warn] '+[].join.call(arguments,' ')); };\n"
        @"  g.console.error=function(){ w('[error] '+[].join.call(arguments,' ')); };\n"
        @"  var tick=[], unload=[];\n"
        @"  g.onTick=function(f){ if(typeof f==='function') tick.push(f); };\n"
        @"  g.onUnload=function(f){ if(typeof f==='function') unload.push(f); };\n"
        @"  g.__pd_unload=function(){ for(var i=unload.length-1;i>=0;i--){ try{unload[i]();}catch(e){w('[unload] '+e);} } unload.length=0; tick.length=0; };\n"
        @"  g.Native={ info:{bid:BID,pid:%d,root:ROOT}, log:g.console.log, reload:function(){ w('[reload] 请在容器 App 里改脚本，热重载由加载器负责'); } };\n"
        @"  if(typeof g.setInterval==='function'){\n"
        @"    g.__pd_interval=g.setInterval(function(){ for(var i=0;i<tick.length;i++){ try{ tick[i](0.033); }catch(e){ w('[tick] '+e); } } },33);\n"
        @"    w('[pandora] 前置就绪，onTick 由 PuerTS 的 setInterval 驱动');\n"
        @"  } else {\n"
        @"    w('[pandora] 这个游戏的 PuerTS 没有 setInterval，onTick 不会自动跑');\n"
        @"  }\n"
        @"})(globalThis);\n",
        log, bid, root, getpid()];
}

@interface PdPandoraRuntime : NSObject <PdRuntime>
@property (nonatomic) void *env;          // Il2CppObject* JsEnv
@property (nonatomic) void *envCls;
@property (nonatomic) void *evalMethod;   // MethodInfo*
@property (atomic) int generation;        // 加载代际：reload/unload 时 +1，
                                          // 后台启动线程发现代数变了就自行退出
@end

@implementation PdPandoraRuntime

- (BOOL)ensureEnvWithError:(NSError **)error {
    if (_env && _evalMethod) return YES;

    NSString *err = pd_il2_load();
    if (err) {
        if (error) *error = [NSError errorWithDomain:@"pandora" code:20
                                               userInfo:@{NSLocalizedDescriptionKey: err}];
        return NO;
    }

    void *domain = g_il2.domain_get();
    if (!domain) {
        if (error) *error = [NSError errorWithDomain:@"pandora" code:21 userInfo:@{
            NSLocalizedDescriptionKey: @"il2cpp domain 还没初始化（游戏还没进到能跑 JS 的阶段）"
        }];
        return NO;
    }
    if (g_il2.thread_attach) g_il2.thread_attach(domain);

    void *cls = pd_find_class_any_image(domain, "com.tencent.pandora", "JsEnvManager");
    if (!cls) {
        if (error) *error = [NSError errorWithDomain:@"pandora" code:22 userInfo:@{
            NSLocalizedDescriptionKey: @"没找到 com.tencent.pandora.JsEnvManager —— 这个游戏没内置 PuerTS，用不了 pjs 模式"
        }];
        return NO;
    }

    void *mGet = g_il2.method_from_name(cls, "GetJsEnv", 0);
    if (!mGet) {
        if (error) *error = [NSError errorWithDomain:@"pandora" code:23
                                               userInfo:@{NSLocalizedDescriptionKey: @"JsEnvManager 没有 GetJsEnv()"}];
        return NO;
    }

    void *exc = NULL;
    void *env = g_il2.invoke(mGet, NULL, NULL, &exc);
    if (exc || !env) {
        if (error) *error = [NSError errorWithDomain:@"pandora" code:24
                                               userInfo:@{NSLocalizedDescriptionKey: @"GetJsEnv() 返回空"}];
        return NO;
    }

    void *envCls = *(void **)env;          // Il2CppObject 首个指针就是 klass
    void *eval = pd_pick_eval(envCls);
    if (!eval) {
        if (error) *error = [NSError errorWithDomain:@"pandora" code:25
                                               userInfo:@{NSLocalizedDescriptionKey: @"JsEnv 上找不到 Eval(string,string)"}];
        return NO;
    }

    _env = env;
    _envCls = envCls;
    _evalMethod = eval;
    PdLog(@"[pjs] 已挂上游戏自己的 JsEnv");
    return YES;
}

/// 成功返回 nil，失败返回原因
- (NSString *)eval:(NSString *)src chunk:(NSString *)chunk {
    void *args[2] = { g_il2.string_new(src.UTF8String), g_il2.string_new(chunk.UTF8String) };
    void *exc = NULL;
    g_il2.invoke(_evalMethod, _env, args, &exc);
    if (exc) {
        /* 尽力把 C# 异常转成可读字符串 */
        void *ecls = *(void **)exc;
        void *toStr = g_il2.method_from_name(ecls, "ToString", 0);
        if (toStr) {
            void *e2 = NULL;
            void *s = g_il2.invoke(toStr, exc, NULL, &e2);
            if (!e2 && s) {
                /* Il2CppString 布局：头两指针之后是 length(int32)，再之后是 UTF-16 字符 */
                int32_t len = *(int32_t *)((uint8_t *)s + 16);
                const uint16_t *chars = (const uint16_t *)((uint8_t *)s + 20);
                if (len > 0 && len < 4096) {
                    NSString *msg = [[NSString alloc] initWithCharacters:(const unichar *)chars length:(NSUInteger)len];
                    return msg ?: @"Eval 抛了异常";
                }
            }
        }
        return @"Eval 抛了异常（ToString 也失败了）";
    }
    return nil;
}

- (BOOL)loadFiles:(NSArray<PdScriptFile *> *)files error:(NSError **)error {
    /* il2cpp domain 和 JsEnvManager 要等游戏真正跑起来才存在。
       游戏刚启动时 ensureEnv 必然失败 —— 旧写法在这里同步试一次就放弃，
       之后再也没有 js.log / [pjs] 日志（失败原因还是异步落盘，游戏被杀就丢），
       表现就是 pandora.log 停在 [apply] 之后一片空白。
       现在放后台线程轮询：5 秒一次、最多 150 秒，覆盖游戏加载全程，
       每次尝试的原因都写进 pandora.log。 */
    int gen = ++self.generation;
    NSArray *snapshot = [files copy];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self bootAndEval:snapshot generation:gen];
    });
    return YES;
}

/* 后台线程：等环境就绪，然后 prelude + 脚本。代数不匹配立即退出。 */
- (void)bootAndEval:(NSArray<PdScriptFile *> *)files generation:(int)gen {
    NSError *err = nil;
    BOOL ok = NO;

    for (int attempt = 1; attempt <= 30 && gen == self.generation; attempt++) {
        err = nil;
        if ([self ensureEnvWithError:&err]) { ok = YES; break; }
        if (attempt == 1 || attempt % 6 == 0) {
            PdLog(@"[pjs] 第 %d 次尝试还没就绪：%@", attempt, err.localizedDescription);
        }
        for (int i = 0; i < 50 && gen == self.generation; i++) {
            [NSThread sleepForTimeInterval:0.1];   /* 5 秒，分段睡以便及时中断 */
        }
    }

    if (gen != self.generation) return;            /* 期间被 reload/unload 打断 */
    if (!ok) {
        PdLog(@"[pjs] 150 秒内没挂上游戏的 JsEnv，放弃。最后原因：%@",
              err.localizedDescription ?: @"未知");
        return;
    }


    NSString *logPath = [PdRootDir() stringByAppendingPathComponent:@"js.log"];
    [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];

    NSString *pre = pd_pjs_prelude(logPath);
    NSString *e = [self eval:pre chunk:@"__pandora_prelude"];
    if (e) {
        PdLog(@"[pjs] 前置脚本执行失败：%@", e);
        return;
    }

    for (PdScriptFile *f in files) {
        if (gen != self.generation) return;
        NSString *src = [[NSString alloc] initWithData:f.data encoding:NSUTF8StringEncoding];
        if (!src) {
            PdLog(@"[pjs] %@ 不是合法 UTF-8，跳过", f.name);
            continue;
        }
        /* 包一层 try：脚本出错不能把整个 VM 的后续执行带崩 */
        NSString *wrapped = [NSString stringWithFormat:
            @"try{\n%@\n}catch(e){ console.error('[%@] ' + (e && e.stack ? e.stack : e)); }\n",
            src, f.name];

        NSString *err2 = [self eval:wrapped chunk:f.name];
        if (err2) PdLog(@"[pjs] %@ 执行失败: %@", f.name, err2);
        else      PdLog(@"[pjs] %@ 已注入游戏 VM (%lu 字节)", f.name, (unsigned long)f.data.length);
    }
}

- (void)tickWithDelta:(double)dt {
    (void)dt;   /* onTick 由游戏自己的 PuerTS 计时器驱动，这里不用管 */
}

- (void)unload {
    self.generation++;   /* 通知后台启动线程立即停止 */
    if (!_evalMethod) return;
    [self eval:@"try{ if(typeof __pd_unload==='function') __pd_unload(); }catch(e){}" chunk:@"__pandora_unload"];
    _env = NULL;
    _evalMethod = NULL;
}

@end
