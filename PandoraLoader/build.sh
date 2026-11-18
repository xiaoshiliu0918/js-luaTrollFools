#!/usr/bin/env bash
#
#  build.sh —— 一键出 Pandora.tipa
#
#  产物结构：
#      Payload/Pandora.app/Pandora                 容器 App
#      Payload/Pandora.app/PandoraLoader.dylib     注入进目标 App 的 payload
#      Payload/Pandora.app/Info.plist
#
#  依赖：macOS + Xcode 命令行工具 + ldid（brew install ldid）
#
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Pandora"
BUNDLE_ID="com.pandora.loader"
MIN_IOS="14.0"
BUILD="build"
APP="$BUILD/Payload/$APP_NAME.app"
OBJ="$BUILD/obj"

command -v xcrun >/dev/null || { echo "缺少 xcrun（装 Xcode 命令行工具）"; exit 1; }
xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1 || { echo "找不到 iPhoneOS SDK"; exit 1; }

echo "==> 清理"
rm -rf "$BUILD"
mkdir -p "$APP" "$OBJ"

ARCH_FLAGS=(-arch arm64 -arch arm64e)

# ------------------------------------------------------------------ Lua（可选）
LUA_CFLAGS=""
LUA_OBJS=""
LUA_COUNT=0
if [ -d "third_party/lua" ] && ls third_party/lua/*.c >/dev/null 2>&1; then
    echo "==> 编译 Lua 5.4"
    for f in third_party/lua/*.c; do
        b="$(basename "$f" .c)"
        case "$b" in
            lua|luac|onelua) continue ;;   # 这两个带 main()
        esac
        xcrun -sdk iphoneos clang "${ARCH_FLAGS[@]}" -miphoneos-version-min=$MIN_IOS \
              -O2 -fno-stack-protector -c "$f" -Ithird_party/lua -o "$OBJ/lua_$b.o"
        LUA_OBJS="$LUA_OBJS $OBJ/lua_$b.o"
        LUA_COUNT=$((LUA_COUNT+1))
    done
    LUA_CFLAGS="-Ithird_party/lua"
    echo "    内置 Lua：$LUA_COUNT 个对象"
else
    echo "==> 跳过 Lua（third_party/lua 不存在，只支持 .js）"
fi

# ------------------------------------------------------------------ payload
echo "==> 编译 PandoraLoader.dylib"
xcrun -sdk iphoneos clang++ "${ARCH_FLAGS[@]}" -miphoneos-version-min=$MIN_IOS \
      -fobjc-arc -O2 \
      -dynamiclib -install_name /usr/lib/PandoraLoader.dylib \
      -Ipayload -Icommon $LUA_CFLAGS \
      -o "$APP/PandoraLoader.dylib" \
      payload/PdEntry.mm \
      payload/PdClient.mm \
      payload/PdJS.mm \
      payload/PdPandora.mm \
      payload/PdLua.mm \
      payload/PdHttp.m \
      payload/PdLog.mm \
      $LUA_OBJS \
      -framework Foundation -framework UIKit \
      -framework JavaScriptCore -framework QuartzCore

# ------------------------------------------------------------------ 容器 App
echo "==> 编译容器 App"
xcrun -sdk iphoneos clang "${ARCH_FLAGS[@]}" -miphoneos-version-min=$MIN_IOS \
      -fobjc-arc -O2 \
      -Iapp -Iinject -Icommon \
      -o "$APP/Pandora" \
      app/main.m \
      app/PDUI.m \
      app/PDStore.m \
      app/PDHostServer.m \
      app/PDTargets.m \
      app/PDTools.m \
      app/PDPatch.m \
      inject/remote.c \
      -framework UIKit -framework Foundation \
      -framework AVFoundation -framework UniformTypeIdentifiers

cp app/Info.plist "$APP/Info.plist"

# 可选：把 insert_dylib / ldid / ct_bypass / libiosexec 放进 tools_bin/，
# 就会打进 Pandora.app/tools/，不再依赖设备上装着 TrollFools。
if [ -d tools_bin ]; then
    echo "==> 打包自带工具链"
    mkdir -p "$APP/tools"
    cp -R tools_bin/. "$APP/tools/" 2>/dev/null || true
    chmod +x "$APP/tools/"* 2>/dev/null || true
fi

# ------------------------------------------------------------------ 签名
LDID="$(command -v ldid || true)"
if [ -z "$LDID" ] && [ -x "${THEOS:-/opt/theos}/bin/ldid" ]; then
    LDID="${THEOS:-/opt/theos}/bin/ldid"
fi

if [ -n "$LDID" ]; then
    echo "==> 签名（ldid）"
    if [ -f "$APP/Pandora" ]; then
        "$LDID" -Sapp/entitlements.plist "$APP/Pandora"
    fi
    "$LDID" -S "$APP/PandoraLoader.dylib"
else
    echo "!! 没找到 ldid，跳过签名。"
    echo "   brew install ldid  然后重跑；否则 TrollStore 装不上。"
fi

# ------------------------------------------------------------------ payload-only 模式
# SLTrollFools 那边的构建只需要 PandoraLoader.dylib —— 容器 App 和注入器
# （task_for_pid + 远程 dlopen）在 SLTrollFools 里已经有等价物，而且
# inject/remote.c 与 app/PDTargets.m 依赖 iOS 公开 SDK 没有的 libproc.h 和
# mach_vm.h（后者在 iOS SDK 里直接 #error）。--payload-only 就是为这种情况设的。
if [ "$1" = "--payload-only" ]; then
    echo "==> --payload-only：跳过容器 App / 注入器 / 打包"
    echo "完成：$APP/PandoraLoader.dylib"
    exit 0
fi

# ------------------------------------------------------------------ 打包
echo "==> 打包"
rm -f "$APP_NAME.tipa"
( cd "$BUILD" && zip -qry "../$APP_NAME.tipa" Payload )

echo
echo "完成：$(pwd)/$APP_NAME.tipa  ($(du -h "$APP_NAME.tipa" | cut -f1))"
if [ "$LUA_COUNT" -gt 0 ]; then echo "运行时：js（自带 JSC） / pjs（游戏 PuerTS） / lua"; else echo "运行时：js（自带 JSC） / pjs（游戏 PuerTS）；未内置 Lua"; fi
