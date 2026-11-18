// hello.js —— 最小验证脚本
//
// 放到容器的「脚本」页里，游戏注入成功后 1 秒内就会开始跑。
// 改这个文件保存 → 注入端下一次轮询发现版本号变了 → 自动重载（不用重启游戏）。

(function () {
    var n = 0;

    console.log('hello from ' + Native.info.bid + ' · iOS ' + Native.info.ios);

    onTick(function (dt) {
        n++;
        if (n % 300 === 0) {             // 30fps 下大约每 10 秒一行
            console.log('alive ' + n + ' frames, dt=' + dt.toFixed(3));
        }
    });

    onUnload(function () {
        console.log('unload after ' + n + ' frames');
    });
})();
