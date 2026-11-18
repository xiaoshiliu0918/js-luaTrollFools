//
//  prelude.js —— 每个脚本执行前先跑这一段
//
//  它提供的东西，就是「加载器」对脚本的全部承诺：
//    console.log/warn/error
//    setTimeout / setInterval / clearTimeout / clearInterval   （由渲染帧驱动，不是真线程）
//    onTick(fn) / onUnload(fn)
//    Native.log / Native.reload / Native.read / Native.write / Native.info
//
//  没有模块系统：一个 bundle 里的文件按名字顺序在**同一个全局作用域**里执行，
//  main.js 永远第一个，所以它可以当入口、给后面的文件定义共享变量。
//

(function (g) {
  'use strict';

  var info = (typeof __pd_info === 'function') ? __pd_info() : {
    bid: '', pid: 0, root: '', ios: ''
  };

  /* ---------------- 格式化 ---------------- */

  function fmt(v) {
    if (typeof v === 'string') return v;
    if (v instanceof Error) return v.stack || (v.name + ': ' + v.message);
    if (typeof v === 'function') return '[function ' + (v.name || 'anonymous') + ']';
    if (v === undefined) return 'undefined';
    try {
      var s = JSON.stringify(v);
      return s === undefined ? String(v) : s;
    } catch (e) {
      return String(v);
    }
  }

  function joinArgs(a) {
    var out = [];
    for (var i = 0; i < a.length; i++) out.push(fmt(a[i]));
    return out.join(' ');
  }

  /* ---------------- console ---------------- */

  g.console = {
    log:   function () { __pd_log(joinArgs(arguments)); },
    info:  function () { __pd_log('[info] ' + joinArgs(arguments)); },
    warn:  function () { __pd_log('[warn] ' + joinArgs(arguments)); },
    error: function () { __pd_log('[error] ' + joinArgs(arguments)); },
    debug: function () { __pd_log('[debug] ' + joinArgs(arguments)); }
  };

  /* ---------------- 定时器（帧驱动） ---------------- */

  var timers = new Map();
  var timerSeq = 1;

  g.setTimeout = function (fn, ms) {
    if (typeof fn !== 'function') return 0;
    var args = Array.prototype.slice.call(arguments, 2);
    var id = timerSeq++;
    timers.set(id, { fn: fn, args: args, due: 0, delay: Math.max(0, ms | 0), repeat: false, armed: false });
    return id;
  };

  g.setInterval = function (fn, ms) {
    if (typeof fn !== 'function') return 0;
    var args = Array.prototype.slice.call(arguments, 2);
    var id = timerSeq++;
    timers.set(id, { fn: fn, args: args, due: 0, delay: Math.max(1, ms | 0), repeat: true, armed: false });
    return id;
  };

  g.clearTimeout = g.clearInterval = function (id) { timers.delete(id); };

  function runTimers(now) {
    if (timers.size === 0) return;
    var fired = [];
    timers.forEach(function (t, id) {
      if (!t.armed) { t.armed = true; t.due = now + t.delay; return; }
      if (now >= t.due) { t.due = now + t.delay; fired.push([id, t]); }
    });
    for (var i = 0; i < fired.length; i++) {
      var id = fired[i][0], t = fired[i][1];
      if (!t.repeat) timers.delete(id);
      try { t.fn.apply(null, t.args); }
      catch (e) { __pd_log('[timer] ' + (e && e.stack ? e.stack : e)); }
    }
  }

  /* ---------------- 生命周期 ---------------- */

  var tickers = [];
  var unloaders = [];

  g.onTick = function (fn) {
    if (typeof fn === 'function') tickers.push({ fn: fn, errors: 0 });
    return fn;
  };

  g.onUnload = function (fn) {
    if (typeof fn === 'function') unloaders.push(fn);
    return fn;
  };

  g.__pd_tick = function (dt, now) {
    runTimers(now);
    if (tickers.length === 0) return;
    for (var i = 0; i < tickers.length; i++) {
      var t = tickers[i];
      try {
        t.fn(dt);
      } catch (e) {
        t.errors++;
        __pd_log('[tick] ' + (e && e.stack ? e.stack : e));
        if (t.errors >= 3) {
          __pd_log('[tick] 连续出错 3 次，已停用该回调');
          tickers.splice(i--, 1);
          if (typeof g.onError === 'function') { try { g.onError(e); } catch (e2) {} }
        }
      }
    }
  };

  g.__pd_unload = function () {
    for (var i = unloaders.length - 1; i >= 0; i--) {
      try { unloaders[i](); } catch (e) { __pd_log('[unload] ' + (e && e.stack ? e.stack : e)); }
    }
    unloaders.length = 0;
    tickers.length = 0;
    timers.clear();
  };

  /* ---------------- Native ---------------- */

  g.Native = {
    info: info,
    log: function () { __pd_log(joinArgs(arguments)); },
    reload: function () { __pd_reload(); },
    read: function (p) { return __pd_read(p); },
    write: function (p, s) { return __pd_write(p, s); }
  };

  g.global = g;

  __pd_log('脚本环境就绪 · ' + (info.bid || '?') + ' · iOS ' + info.ios);
})(globalThis);
