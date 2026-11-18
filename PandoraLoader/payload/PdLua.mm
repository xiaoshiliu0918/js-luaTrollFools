//
//  PdLua.mm —— Lua 5.4 运行时（可选）
//
//  iOS 没有系统 Lua，必须自带源码：
//      git clone -b v5.4.6 --depth 1 https://github.com/lua/lua third_party/lua
//  build.sh 会自动检测 third_party/lua/*.c 并打开 -DPD_HAS_LUA=1。
//  没有源码时这个文件编译成空壳，PdRuntimeFactory 会告诉用户「本包不含 Lua」。
//
//  脚本约定：
//      function on_tick(dt) end
//      function on_unload() end
//      native.log("...")  native.reload()  native.bid / native.pid / native.ver
//

#import "PdRuntime.h"
#import "PdLog.h"

#if __has_include("lua.h")

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include <unistd.h>

/* 单次 tick 的执行预算：超过就报错，避免 while true do end 把游戏卡死。
 * 用 CFAbsoluteTime 而不是 CPU 时间 —— 脚本阻塞时 CPU 时间照样在涨，
 * 但阻塞 sleep 的时候不会，wall clock 才是我们要的。 */
static double g_lua_deadline = 0;

static inline double pd_now(void) { return CFAbsoluteTimeGetCurrent(); }

static void pd_lua_hook(lua_State *L, lua_Debug *ar) {
    (void)ar;
    if (g_lua_deadline <= 0) return;
    if (pd_now() < g_lua_deadline) return;
    luaL_error(L, "脚本执行超时（单次超过 500ms），已中断");
}

static void pd_lua_set_budget(lua_State *L) {
    g_lua_deadline = pd_now() + 0.5;
    lua_sethook(L, pd_lua_hook, LUA_MASKCOUNT, 20000);
}

static void pd_lua_clear_budget(lua_State *L) {
    g_lua_deadline = 0;
    lua_sethook(L, NULL, 0, 0);
}

/* ---- native.* ---- */

static int nl_log(lua_State *L) {
    int n = lua_gettop(L);
    luaL_Buffer b;
    luaL_buffinit(L, &b);
    for (int i = 1; i <= n; i++) {
        const char *s = luaL_tolstring(L, i, NULL);
        if (s) luaL_addstring(&b, s);
        lua_pop(L, 1);
        if (i != n) luaL_addchar(&b, '\t');
    }
    luaL_pushresult(&b);
    PdLog(@"[lua] %s", lua_tostring(L, -1));
    lua_pop(L, 1);
    return 0;
}

static int nl_reload(lua_State *L) {
    (void)L;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"PdForceReload" object:nil];
    return 0;
}

static int nl_read(lua_State *L) {
    const char *p = luaL_checkstring(L, 1);
    NSString *path = [NSString stringWithUTF8String:p];
    if (![path hasPrefix:@"/"]) path = [PdRootDir() stringByAppendingPathComponent:path];
    NSString *s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (s) lua_pushlstring(L, s.UTF8String, strlen(s.UTF8String));
    else lua_pushnil(L);
    return 1;
}

static int nl_write(lua_State *L) {
    const char *p = luaL_checkstring(L, 1);
    size_t len = 0;
    const char *s = luaL_checklstring(L, 2, &len);
    NSString *path = [NSString stringWithUTF8String:p];
    if (![path hasPrefix:@"/"]) path = [PdRootDir() stringByAppendingPathComponent:path];
    NSData *d = [NSData dataWithBytes:s length:len];
    BOOL ok = [d writeToFile:path atomically:YES];
    lua_pushboolean(L, ok);
    return 1;
}

@interface PdLuaRuntime : NSObject <PdRuntime>
@end

@implementation PdLuaRuntime {
    lua_State *_L;
}

- (instancetype)init {
    if ((self = [super init])) {
        _L = luaL_newstate();
        if (_L) {
            luaL_openlibs(_L);

            lua_newtable(_L);
            lua_pushcfunction(_L, nl_log);    lua_setfield(_L, -2, "log");
            lua_pushcfunction(_L, nl_reload); lua_setfield(_L, -2, "reload");
            lua_pushcfunction(_L, nl_read);   lua_setfield(_L, -2, "read");
            lua_pushcfunction(_L, nl_write);  lua_setfield(_L, -2, "write");
            lua_pushstring(_L, [[[NSBundle mainBundle] bundleIdentifier] ?: @"" UTF8String]);
            lua_setfield(_L, -2, "bid");
            lua_pushinteger(_L, getpid());
            lua_setfield(_L, -2, "pid");
            lua_setglobal(_L, "native");

            /* print 改到统一日志里，否则 Lua 的输出在 iOS 上看不见 */
            lua_pushcfunction(_L, nl_log);
            lua_setglobal(_L, "print");
        }
    }
    return self;
}

- (BOOL)loadFiles:(NSArray<PdScriptFile *> *)files error:(NSError **)error {
    if (!_L) {
        if (error) *error = [NSError errorWithDomain:@"pandora" code:10
                                               userInfo:@{NSLocalizedDescriptionKey: @"luaL_newstate 失败"}];
        return NO;
    }
    for (PdScriptFile *f in files) {
        NSString *src = [[NSString alloc] initWithData:f.data encoding:NSUTF8StringEncoding];
        if (!src) { PdLog(@"[lua] %@ 不是合法 UTF-8", f.name); continue; }

        pd_lua_set_budget(_L);
        int rc = luaL_loadbufferx(_L, src.UTF8String, strlen(src.UTF8String), f.name.UTF8String, "t");
        if (rc == LUA_OK) rc = lua_pcall(_L, 0, 0, 0);
        pd_lua_clear_budget(_L);

        if (rc != LUA_OK) {
            const char *msg = lua_tostring(_L, -1);
            PdLog(@"[lua] %@ 执行失败: %s", f.name, msg ?: "?");
            lua_pop(_L, 1);
        } else {
            PdLog(@"[lua] %@ 已加载 (%lu 字节)", f.name, (unsigned long)f.data.length);
        }
    }
    return YES;
}

- (void)tickWithDelta:(double)dt {
    if (!_L) return;
    lua_getglobal(_L, "on_tick");
    if (!lua_isfunction(_L, -1)) { lua_pop(_L, 1); return; }

    lua_pushnumber(_L, dt);
    pd_lua_set_budget(_L);
    int rc = lua_pcall(_L, 1, 0, 0);
    pd_lua_clear_budget(_L);

    if (rc != LUA_OK) {
        PdLog(@"[lua] on_tick 出错: %s", lua_tostring(_L, -1) ?: "?");
        lua_pop(_L, 1);
    }
}

- (void)unload {
    if (!_L) return;
    lua_getglobal(_L, "on_unload");
    if (lua_isfunction(_L, -1)) {
        pd_lua_set_budget(_L);
        lua_pcall(_L, 0, 0, 0);
        pd_lua_clear_budget(_L);
    } else {
        lua_pop(_L, 1);
    }
    lua_close(_L);
    _L = NULL;
}

- (void)dealloc {
    if (_L) { lua_close(_L); _L = NULL; }
}

@end

#endif /* __has_include("lua.h") */
