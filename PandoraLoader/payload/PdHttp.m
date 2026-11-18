#import "PdHttp.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <errno.h>
#import <fcntl.h>
#import <string.h>

static BOOL pd_wait(int fd, BOOL forRead, NSTimeInterval timeout) {
    fd_set set;
    FD_ZERO(&set);
    FD_SET(fd, &set);
    struct timeval tv;
    tv.tv_sec = (time_t)timeout;
    tv.tv_usec = (suseconds_t)((timeout - tv.tv_sec) * 1e6);
    int rc = select(fd + 1, forRead ? &set : NULL, forRead ? NULL : &set, NULL, &tv);
    return rc > 0;
}

NSData *PdHttpGet(int port, NSString *path, NSTimeInterval timeout, NSString **err) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { if (err) *err = @"socket() 失败"; return nil; }

    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    /* 非阻塞 connect + select，这样 connect 也有超时 */
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons((uint16_t)port);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

    int rc = connect(fd, (struct sockaddr *)&a, sizeof(a));
    if (rc < 0 && errno != EINPROGRESS) {
        if (err) *err = [NSString stringWithFormat:@"connect: %s", strerror(errno)];
        close(fd);
        return nil;
    }
    if (rc < 0) {
        if (!pd_wait(fd, NO, timeout)) {
            if (err) *err = @"connect 超时（容器 App 在后台被挂起了？）";
            close(fd);
            return nil;
        }
        int soerr = 0;
        socklen_t len = sizeof(soerr);
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &len);
        if (soerr != 0) {
            if (err) *err = [NSString stringWithFormat:@"connect: %s", strerror(soerr)];
            close(fd);
            return nil;
        }
    }

    fcntl(fd, F_SETFL, flags);

    NSString *req = [NSString stringWithFormat:
                     @"GET %@ HTTP/1.0\r\nHost: 127.0.0.1:%d\r\n"
                     @"User-Agent: PandoraLoader/1\r\nConnection: close\r\n\r\n",
                     path, port];
    const char *bytes = req.UTF8String;
    size_t left = strlen(bytes);
    while (left > 0) {
        ssize_t n = send(fd, bytes, left, 0);
        if (n <= 0) {
            if (err) *err = [NSString stringWithFormat:@"send: %s", strerror(errno)];
            close(fd);
            return nil;
        }
        bytes += n;
        left -= (size_t)n;
    }

    NSMutableData *raw = [NSMutableData data];
    char buf[8192];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (YES) {
        NSTimeInterval remain = [deadline timeIntervalSinceNow];
        if (remain <= 0) break;
        if (!pd_wait(fd, YES, remain)) break;
        ssize_t n = recv(fd, buf, sizeof(buf), 0);
        if (n <= 0) break;
        [raw appendBytes:buf length:(NSUInteger)n];
        if (raw.length > 8 * 1024 * 1024) break;   /* 防御：单个脚本不该超过 8MB */
    }
    close(fd);

    if (raw.length == 0) {
        if (err) *err = @"服务端无响应";
        return nil;
    }

    /* 切掉响应头 */
    NSRange sep = [raw rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]
                           options:0 range:NSMakeRange(0, raw.length)];
    if (sep.location == NSNotFound) {
        if (err) *err = @"响应格式错误";
        return nil;
    }

    NSString *head = [[NSString alloc] initWithData:[raw subdataWithRange:NSMakeRange(0, sep.location)]
                                           encoding:NSUTF8StringEncoding];
    if ([head hasPrefix:@"HTTP/1."] && head.length > 9) {
        NSInteger code = [[head substringWithRange:NSMakeRange(9, 3)] integerValue];
        if (code != 200) {
            if (err) *err = [NSString stringWithFormat:@"HTTP %ld", (long)code];
            return nil;
        }
    }

    return [raw subdataWithRange:NSMakeRange(NSMaxRange(sep), raw.length - NSMaxRange(sep))];
}
