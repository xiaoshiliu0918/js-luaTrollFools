#import "PDTools.h"
#import <dlfcn.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>
#import <errno.h>
#import <string.h>
#import <signal.h>

extern char **environ;

typedef int (*pd_ie_spawn_t)(pid_t *, const char *,
                             const posix_spawn_file_actions_t *,
                             const posix_spawnattr_t *,
                             char *const[], char *const[]);

@implementation PDTools

+ (NSString *)trollFoolsBundle {
    static NSString *cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray *roots = @[@"/var/containers/Bundle/Application", @"/Applications"];
        for (NSString *root in roots) {
            for (NSString *uuid in [fm contentsOfDirectoryAtPath:root error:NULL]) {
                NSString *app = [[root stringByAppendingPathComponent:uuid]
                                 stringByAppendingPathComponent:@"TrollFools.app"];
                NSString *plist = [app stringByAppendingPathComponent:@"Info.plist"];
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plist];
                if (!info) continue;

                NSString *bid = info[@"CFBundleIdentifier"] ?: @"";
                if ([bid isEqualToString:@"wiki.qaq.TrollFools"] ||
                    [app.lastPathComponent.lowercaseString containsString:@"trollfools"]) {
                    cached = app;
                    return;
                }
            }
        }
    });
    return cached;
}

+ (NSString *)toolPath:(NSString *)name {
    NSString *own = [[[NSBundle mainBundle] bundlePath]
                     stringByAppendingPathComponent:[@"tools" stringByAppendingPathComponent:name]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:own]) return own;

    NSString *tf = [self trollFoolsBundle];
    if (!tf) return nil;
    NSString *p = [tf stringByAppendingPathComponent:name];
    return [[NSFileManager defaultManager] fileExistsAtPath:p] ? p : nil;
}

+ (BOOL)available {
    return [self missingTools].length == 0;
}

+ (NSString *)missingTools {
    NSMutableArray *miss = [NSMutableArray array];
    for (NSString *n in @[@"insert_dylib", @"ldid", @"ct_bypass"]) {
        if (![self toolPath:n]) [miss addObject:n];
    }
    if (![self toolPath:@"libiosexec.1.dylib"]) [miss addObject:@"libiosexec.1.dylib"];
    return [miss componentsJoinedByString:@", "];
}

+ (BOOL)run:(NSString *)tool
       args:(NSArray<NSString *> *)args
     output:(NSString **)output
      error:(NSString **)error {

    NSString *path = [self toolPath:tool];
    if (!path) {
        if (error) *error = [NSString stringWithFormat:@"找不到工具 %@", tool];
        return NO;
    }

    /* argv */
    NSMutableArray *all = [NSMutableArray arrayWithObject:path];
    [all addObjectsFromArray:args];

    char **argv = calloc(all.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < all.count; i++) argv[i] = strdup([all[i] UTF8String]);
    argv[all.count] = NULL;

    /* 管道收输出 */
    int fds[2];
    if (pipe(fds) != 0) {
        if (error) *error = @"pipe 失败";
        for (NSUInteger i = 0; i < all.count; i++) free(argv[i]);
        free(argv);
        return NO;
    }

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&fa, fds[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&fa, fds[0]);
    posix_spawn_file_actions_addclose(&fa, fds[1]);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT);

    pid_t pid = -1;
    int rc = -1;

    /* 优先用 libiosexec：否则 iOS 会拒绝 exec 应用包内的二进制 */
    NSString *libPath = [self toolPath:@"libiosexec.1.dylib"];
    static pd_ie_spawn_t ie_spawn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!libPath) return;
        void *h = dlopen(libPath.fileSystemRepresentation, RTLD_NOW);
        if (h) ie_spawn = (pd_ie_spawn_t)dlsym(h, "ie_posix_spawn");
    });

    if (ie_spawn) {
        rc = ie_spawn(&pid, path.fileSystemRepresentation, &fa, &attr, argv, environ);
    }
    if (rc != 0 || pid <= 0) {
        rc = posix_spawn(&pid, path.fileSystemRepresentation, &fa, &attr, argv, environ);
    }

    posix_spawn_file_actions_destroy(&fa);
    posix_spawnattr_destroy(&attr);
    close(fds[1]);

    for (NSUInteger i = 0; i < all.count; i++) free(argv[i]);
    free(argv);

    if (rc != 0) {
        close(fds[0]);
        if (error) *error = [NSString stringWithFormat:@"启动 %@ 失败: %s", tool, strerror(rc)];
        return NO;
    }

    NSMutableData *buf = [NSMutableData data];
    char tmp[4096];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:60];
    while ([deadline timeIntervalSinceNow] > 0) {
        ssize_t n = read(fds[0], tmp, sizeof(tmp));
        if (n <= 0) break;
        [buf appendBytes:tmp length:(NSUInteger)n];
        if (buf.length > 256 * 1024) break;
    }
    close(fds[0]);

    /* 收尸，带超时 */
    int status = 0;
    BOOL reaped = NO;
    for (int i = 0; i < 600; i++) {
        pid_t w = waitpid(pid, &status, WNOHANG);
        if (w == pid) { reaped = YES; break; }
        usleep(100 * 1000);
    }
    if (!reaped) {
        kill(pid, SIGKILL);
        waitpid(pid, &status, 0);
    }

    NSString *out = [[NSString alloc] initWithData:buf encoding:NSUTF8StringEncoding] ?: @"";
    if (output) *output = out;
    if (error) *error = out;

    if (!reaped) return NO;
    if (WIFEXITED(status)) return WEXITSTATUS(status) == 0;
    return NO;   /* 被信号打死 */
}

@end
