#import "PDHostServer.h"
#import "PDStore.h"
#import "PdProtocol.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>

@interface PDHostServer ()
@property (nonatomic) int listenFD;
@property (nonatomic, strong) dispatch_source_t src;
@property (nonatomic, strong) dispatch_queue_t q;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary *> *seen;
@property (nonatomic, strong) NSLock *lock;
@end

@implementation PDHostServer

+ (instancetype)shared {
    static PDHostServer *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [PDHostServer new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _listenFD = -1;
        _port = PD_PORT;
        _q = dispatch_queue_create("pandora.http", DISPATCH_QUEUE_SERIAL);
        _seen = [NSMutableDictionary dictionary];
        _lock = [NSLock new];
    }
    return self;
}

#pragma mark - 启停

- (BOOL)startOnPort:(int)port error:(NSString **)err {
    if (_listenFD >= 0) {
        if (port == _port) return YES;
        [self stop];
    }

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { if (err) *err = @"socket() 失败"; return NO; }

    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));

    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons((uint16_t)port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);   /* 只回环，不对外 */

    if (bind(fd, (struct sockaddr *)&a, sizeof(a)) != 0) {
        if (err) *err = [NSString stringWithFormat:@"绑定 127.0.0.1:%d 失败: %s", port, strerror(errno)];
        close(fd);
        return NO;
    }
    if (listen(fd, 16) != 0) {
        if (err) *err = [NSString stringWithFormat:@"listen 失败: %s", strerror(errno)];
        close(fd);
        return NO;
    }

    _listenFD = fd;
    _port = port;

    _src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, _q);
    __weak PDHostServer *weakSelf = self;
    dispatch_source_set_event_handler(_src, ^{ [weakSelf acceptLoop]; });
    dispatch_source_set_cancel_handler(_src, ^{ close(fd); });
    dispatch_resume(_src);

    NSLog(@"[pandora] 脚本服务器已启动 http://127.0.0.1:%d", port);
    return YES;
}

- (void)stop {
    if (_src) { dispatch_source_cancel(_src); _src = nil; }
    if (_listenFD >= 0) { _listenFD = -1; }
}

- (BOOL)running { return _listenFD >= 0; }

#pragma mark - 连接

- (void)acceptLoop {
    for (int i = 0; i < 8; i++) {
        int c = accept(_listenFD, NULL, NULL);
        if (c < 0) break;

        int on = 1;
        setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));
        struct timeval tv = {2, 0};
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            [self handleClient:c];
        });
    }
}

static void pd_send_all(int fd, const void *buf, size_t len) {
    const char *p = (const char *)buf;
    while (len > 0) {
        ssize_t n = send(fd, p, len, 0);
        if (n <= 0) return;
        p += n;
        len -= (size_t)n;
    }
}

static void pd_respond(int fd, int code, const char *type, NSData *body) {
    const char *reason = (code == 200) ? "OK" : (code == 404 ? "Not Found" : "Bad Request");
    char head[256];
    int hl = snprintf(head, sizeof(head),
                      "HTTP/1.0 %d %s\r\n"
                      "Content-Type: %s\r\n"
                      "Content-Length: %lu\r\n"
                      "Connection: close\r\n"
                      "Cache-Control: no-store\r\n\r\n",
                      code, reason, type, (unsigned long)body.length);
    pd_send_all(fd, head, (size_t)hl);
    if (body.length) pd_send_all(fd, body.bytes, body.length);
}

static void pd_respond_text(int fd, int code, NSString *text) {
    pd_respond(fd, code, "text/plain; charset=utf-8", [text dataUsingEncoding:NSUTF8StringEncoding]);
}

static NSDictionary<NSString *, NSString *> *pd_parse_query(NSString *query) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *pair in [query componentsSeparatedByString:@"&"]) {
        NSRange eq = [pair rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *k = [pair substringToIndex:eq.location];
        NSString *v = [pair substringFromIndex:eq.location + 1];
        v = [v stringByRemovingPercentEncoding] ?: v;
        if (k.length) out[k] = v;
    }
    return out;
}

- (void)handleClient:(int)fd {
    char buf[2048];
    ssize_t n = recv(fd, buf, sizeof(buf) - 1, 0);
    if (n <= 0) { close(fd); return; }
    buf[n] = 0;

    /* 只解析请求行：GET /path?query HTTP/1.0 */
    char method[8] = {0}, target[1600] = {0};
    if (sscanf(buf, "%7s %1599s", method, target) != 2 || strcmp(method, "GET") != 0) {
        pd_respond_text(fd, 400, @"bad request");
        close(fd);
        return;
    }

    NSString *t = [NSString stringWithUTF8String:target] ?: @"";
    NSString *path = t, *query = @"";
    NSRange qm = [t rangeOfString:@"?"];
    if (qm.location != NSNotFound) {
        path = [t substringToIndex:qm.location];
        query = [t substringFromIndex:qm.location + 1];
    }
    NSDictionary *q = pd_parse_query(query);

    if ([path isEqualToString:@"/ping"]) {
        pd_respond_text(fd, 200, @"pong");
    }
    else if ([path isEqualToString:@"/manifest"]) {
        NSString *tok = q[@"token"];
        if (tok && ![tok isEqualToString:@PD_TOKEN]) {
            pd_respond_text(fd, 400, @"bad token");
        } else {
            NSArray *files = [[PDStore shared] files];
            NSMutableArray *list = [NSMutableArray array];
            for (NSDictionary *f in files) {
                [list addObject:@{@"name": f[@"name"], @"lang": f[@"lang"],
                                  @"size": f[@"size"], @"mtime": f[@"mtime"]}];
            }
            NSDictionary *man = @{@"proto": @(PD_PROTO_VERSION),
                                  @"ver": @([[PDStore shared] version]),
                                  @"files": list};
            NSData *body = [NSJSONSerialization dataWithJSONObject:man options:0 error:NULL];
            pd_respond(fd, 200, "application/json", body);
        }
    }
    else if ([path isEqualToString:@"/file"]) {
        NSData *d = [[PDStore shared] dataForName:q[@"name"]];
        if (d) pd_respond(fd, 200, "application/octet-stream", d);
        else pd_respond_text(fd, 404, @"not found");
    }
    else if ([path isEqualToString:@"/log"]) {
        NSString *msg = q[@"msg"] ?: @"";
        void (^sink)(NSString *) = self.logSink;
        if (sink) dispatch_async(dispatch_get_main_queue(), ^{ sink(msg); });
        pd_respond_text(fd, 200, @"ok");
    }
    else if ([path isEqualToString:@"/state"]) {
        NSMutableDictionary *st = [q mutableCopy];
        st[@"time"] = @([[NSDate date] timeIntervalSince1970]);
        NSString *bid = q[@"bid"] ?: @"?";
        [_lock lock];
        _seen[bid] = st;
        [_lock unlock];
        void (^sink)(NSDictionary *) = self.stateSink;
        if (sink) {
            NSDictionary *copy = [st copy];
            dispatch_async(dispatch_get_main_queue(), ^{ sink(copy); });
        }
        pd_respond_text(fd, 200, @"ok");
    }
    else {
        pd_respond_text(fd, 404, @"not found");
    }

    close(fd);
}

- (NSArray<NSDictionary *> *)clients {
    [_lock lock];
    NSArray *all = [_seen.allValues copy];
    [_lock unlock];
    return all;
}

@end
