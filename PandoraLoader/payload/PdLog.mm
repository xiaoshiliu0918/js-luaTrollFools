#import "PdLog.h"
#import <pthread.h>

static NSString *g_root = nil;
static NSString *g_path = nil;
static dispatch_queue_t g_q = nil;
static void (^g_fwd)(NSString *) = nil;

NSString *PdRootDir(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (docs.length == 0) docs = NSTemporaryDirectory();
        g_root = [docs stringByAppendingPathComponent:@"Pandora"];
        [[NSFileManager defaultManager] createDirectoryAtPath:g_root
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        g_q = dispatch_queue_create("pandora.log", DISPATCH_QUEUE_SERIAL);
    });
    return g_root;
}

NSString *PdLogPath(void) {
    PdRootDir();
    if (!g_path) g_path = [g_root stringByAppendingPathComponent:@"pandora.log"];
    return g_path;
}

/// 超过 1MB 就砍掉重来。注入端日志量不大，不值得做滚动。
static void pd_rotate_if_needed(void) {
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:PdLogPath() error:NULL];
    if (attr && [attr fileSize] > 1024 * 1024) {
        [[NSFileManager defaultManager] removeItemAtPath:PdLogPath() error:NULL];
    }
}

void PdLogLocal(NSString *line) {
    if (line.length == 0) return;
    dispatch_async(g_q ?: dispatch_get_global_queue(0, 0), ^{
        @try {
            pd_rotate_if_needed();
            NSString *path = PdLogPath();
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            if (!fh) {
                [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
                fh = [NSFileHandle fileHandleForWritingAtPath:path];
            }
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (__unused NSException *e) {
            /* 日志失败不能影响宿主 */
        }
    });
}

void PdLogSetForwarder(void (^forwarder)(NSString *line)) {
    g_fwd = [forwarder copy];
}

void PdLog(NSString *fmt, ...) {
    @autoreleasepool {
        va_list ap;
        va_start(ap, fmt);
        NSString *body = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);

        /* 线程名：Unity 主线程是 1，其它是后台，一眼能看出有没有跨线程调 il2cpp */
        BOOL main = [NSThread isMainThread];
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"HH:mm:ss.SSS";
        NSString *line = [NSString stringWithFormat:@"%@ %@ %@\n",
                          [df stringFromDate:[NSDate date]],
                          main ? @"[M]" : @"[B]",
                          body ?: @""];

        PdLogLocal(line);
        NSLog(@"[pandora] %@", body);

        void (^f)(NSString *) = g_fwd;
        if (f) {
            @try { f(body ?: @""); } @catch (__unused NSException *e) {}
        }
    }
}
