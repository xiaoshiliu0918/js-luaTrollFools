//
//  PdHttp.h —— 极简 HTTP/1.0 客户端
//
//  只用回环地址，所以不需要 TLS、不需要 chunked、不需要重定向。
//  全程带超时：轮询每秒一次，绝不能把主线程或后台队列卡住。
//

#ifndef PD_HTTP_H
#define PD_HTTP_H

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

/// GET http://127.0.0.1:port/path，成功返回 body；失败返回 nil 并写 err
NSData *PdHttpGet(int port, NSString *path, NSTimeInterval timeout, NSString **err);

#ifdef __cplusplus
}
#endif

#endif
