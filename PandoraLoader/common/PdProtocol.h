//
//  PdProtocol.h —— 容器 App（脚本服务器）与注入 dylib（客户端）之间的线协议
//
//  设计约束：注入进目标 App 的 dylib 跑在**目标 App 的沙盒**里，
//  读不到容器 App 的 Documents，所以不能用文件共享，只能走本机回环 socket。
//
//  协议刻意做成 HTTP/1.0 的极简子集，好处是任何工具都能调试：
//      curl 'http://127.0.0.1:38999/manifest?bid=com.tencent.smoba&ver=0'
//      curl 'http://127.0.0.1:38999/file?name=main.js' -o main.js
//      curl 'http://127.0.0.1:38999/log?msg=hello'
//
//  一次交互一个连接，Connection: close，不做 keep-alive —— 代码量最小，出错最好查。
//

#ifndef PD_PROTOCOL_H
#define PD_PROTOCOL_H

#define PD_PORT            38999
#define PD_TOKEN           "pandora-local-2026"   /* 只防同机其它 App 误连，不是安全边界 */
#define PD_PROTO_VERSION   1

/*
 GET /ping
   200  text/plain          "pong"

 GET /manifest?bid=<bundleid>&ver=<int64>&token=<str>
   200  application/json
        {
          "proto": 1,
          "ver":   1731999999123,          // 脚本集合版本，客户端比对用
          "token": "pandora-local-2026",
          "files": [
            { "name": "main.js", "lang": "js", "size": 1234, "mtime": 1731999999 }
          ]
        }
   说明：ver 与客户端当前 ver 相同则客户端什么都不做（热重载的空转路径）。
        files 已按执行顺序排好：先 js 后 lua，同语言按文件名排序，main.* 永远排最前。

 GET /file?name=<filename>
   200  application/octet-stream  ← 原始字节
   404  找不到

 GET /log?msg=<percent-encoded>
   200  text/plain          "ok"      ← 把 dylib 的日志回传到容器 App 的日志页

 GET /state?bid=<bundleid>&ver=<int64>&pid=<int>&msg=<encoded>
   200  text/plain          "ok"      ← 客户端每隔几秒上报一次心跳，App 里能看到「谁连上了」
*/

#endif /* PD_PROTOCOL_H */
