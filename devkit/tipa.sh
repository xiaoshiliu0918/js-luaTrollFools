#!/bin/sh

XCCONFIG_NAME=TrollFools/Version.xcconfig
VERSION=$(awk -F "=" '/VERSION/ {print $2}' $XCCONFIG_NAME | tr -d ' ')
BUILD_NUMBER=$(awk -F "=" '/BUILD_NUMBER/ {print $2}' $XCCONFIG_NAME | tr -d ' ')

mkdir -p packages $THEOS_STAGING_DIR/Payload
cp -rp $THEOS_STAGING_DIR$THEOS_PACKAGE_INSTALL_PREFIX/Applications/TrollFools.app $THEOS_STAGING_DIR/Payload
chmod 0644 $THEOS_STAGING_DIR/Payload/TrollFools.app/Info.plist

# TempInject: bundle the CLI watchdog binary into the .app
if [ -f $THEOS_STAGING_DIR$THEOS_PACKAGE_INSTALL_PREFIX/usr/local/bin/trollfoolscli ]; then
	cp -p $THEOS_STAGING_DIR$THEOS_PACKAGE_INSTALL_PREFIX/usr/local/bin/trollfoolscli $THEOS_STAGING_DIR/Payload/TrollFools.app/trollfoolscli
	chmod 0755 $THEOS_STAGING_DIR/Payload/TrollFools.app/trollfoolscli
fi

# 脚本加载器 payload：放在 .app 根目录（和 insert_dylib / ldid 那些工具同级）。
# PandoraLoader.payloadURL() 先查 Bundle.main 资源，再查可执行文件同目录，
# 所以放这里就能被找到，不需要进 Xcode 的 Resources 阶段。
# 源码在 E:/桌面/PandoraLoader，构建产物叫 PandoraLoader.dylib。
if [ -f TrollFools/PandoraLoader.dylib ]; then
	echo "==> 打包脚本加载器 PandoraLoader.dylib"
	cp -p TrollFools/PandoraLoader.dylib $THEOS_STAGING_DIR/Payload/TrollFools.app/PandoraLoader.dylib
	chmod 0644 $THEOS_STAGING_DIR/Payload/TrollFools.app/PandoraLoader.dylib
else
	echo "==> 未找到 TrollFools/PandoraLoader.dylib，本次打出的包不含脚本加载器"
fi

cd $THEOS_STAGING_DIR
# 7z a -tzip 石榴动态注入.tipa Payload
zip -qr 石榴动态注入.tipa Payload
cd -

cp -p $THEOS_STAGING_DIR/石榴动态注入.tipa packages
