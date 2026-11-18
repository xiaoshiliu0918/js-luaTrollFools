//
//  remote.h —— 运行时注入（attach 方式，不重启目标进程）
//
//  原理四步：
//    1. task_for_pid 拿到目标 task port
//    2. 读目标 dyld_all_image_infos，算出 libdyld 在**目标进程里**的基址，
//       再加上本机 dlopen 相对基址的偏移 → 得到目标进程的 dlopen 地址
//    3. 在目标里分配内存：dylib 路径字符串 + 一段栈 + 一段 ARM64 桩代码
//    4. thread_create_running 起一个线程跑桩：dlopen(path, RTLD_NOW) → pthread_exit
//
//  为什么不在本进程直接取 dlopen 地址：ASLR，两个进程的 slide 不同。
//  为什么用桩而不是直接把 PC 设成 dlopen：dlopen 返回后必须有个去处，
//  直接返回会跳到野地址把目标带崩。桩里调 pthread_exit 干净退出。
//  桩要求 RX 内存；拿不到（内核不允许匿名可执行页）就退化成
//  「PC=dlopen，LR=pthread_exit」，靠函数自己的 PACIASP/AUTIASP 配对保证能返回。
//

#ifndef PD_REMOTE_H
#define PD_REMOTE_H

#include <sys/types.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 把 dylib_path 注入 pid。成功返回 true；失败把原因写进 err。
bool pd_inject_dylib(pid_t pid, const char *dylib_path, char *err, size_t errlen);

/// 只检查能不能拿到 task port（用来在 UI 上先探一下权限）
bool pd_can_attach(pid_t pid, char *err, size_t errlen);

/// 目标进程里是否已经加载了某个镜像（按文件名子串匹配）
bool pd_image_loaded(pid_t pid, const char *needle);

#ifdef __cplusplus
}
#endif

#endif
