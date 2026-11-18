#include "remote.h"

#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/task_info.h>
#include <mach/arm/thread_status.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <libproc.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <errno.h>

#define PD_STACK_SIZE   (512 * 1024)
#define PD_STUB_SIZE    48

static void pd_seterr(char *err, size_t len, const char *fmt, ...) {
    if (!err || len == 0) return;
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, len, fmt, ap);
    va_end(ap);
}

#pragma mark - 基础内存操作

static bool pd_read(mach_port_t task, uint64_t addr, void *buf, size_t len) {
    mach_vm_size_t out = 0;
    kern_return_t kr = mach_vm_read_overwrite(task, addr, len,
                                              (mach_vm_address_t)buf, &out);
    return kr == KERN_SUCCESS && out == len;
}

static bool pd_write(mach_port_t task, uint64_t addr, const void *buf, size_t len) {
    kern_return_t kr = mach_vm_write(task, addr, (vm_offset_t)(uintptr_t)buf, (mach_msg_type_number_t)len);
    return kr == KERN_SUCCESS;
}

static bool pd_alloc(mach_port_t task, size_t len, uint64_t *out) {
    mach_vm_address_t addr = 0;
    kern_return_t kr = mach_vm_allocate(task, &addr, len, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS) return false;
    *out = addr;
    return true;
}

#pragma mark - 目标进程的镜像基址

/// 读目标进程的 dyld_all_image_infos，按文件名找镜像的 __TEXT 基址。
static bool pd_remote_image_base(mach_port_t task, const char *basename, uint64_t *out) {
    struct task_dyld_info tdi;
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    kern_return_t kr = task_info(task, TASK_DYLD_INFO, (task_info_t)&tdi, &count);
    if (kr != KERN_SUCCESS) return false;

    uint64_t aiia = tdi.all_image_info_addr;
    if (aiia == 0) return false;

    /* struct dyld_all_image_infos 开头：
     *   uint32 version; uint32 infoArrayCount; const dyld_image_info *infoArray; ...
     * 64 位下 infoArray 在 +8。 */
    struct { uint32_t version; uint32_t count; uint64_t array; } hdr;
    if (!pd_read(task, aiia, &hdr, sizeof(hdr))) return false;
    if (hdr.count == 0 || hdr.count > 8192 || hdr.array == 0) return false;

    /* struct dyld_image_info { const mach_header *addr; const char *path; uintptr_t modDate; } = 24 字节 */
    for (uint32_t i = 0; i < hdr.count; i++) {
        struct { uint64_t addr; uint64_t path; uint64_t mod; } info;
        if (!pd_read(task, hdr.array + (uint64_t)i * 24, &info, sizeof(info))) continue;
        if (info.addr == 0 || info.path == 0) continue;

        char path[512] = {0};
        if (!pd_read(task, info.path, path, sizeof(path) - 1)) continue;

        const char *slash = strrchr(path, '/');
        const char *name = slash ? slash + 1 : path;
        if (strcmp(name, basename) == 0) {
            *out = info.addr;
            return true;
        }
    }
    return false;
}

/// 某个本机符号在目标进程里的地址 = 目标镜像基址 + (本机符号 - 本机镜像基址)
static bool pd_remote_symbol(mach_port_t task, void *sym, uint64_t *out) {
    Dl_info di;
    if (dladdr(sym, &di) == 0 || di.dli_fname == NULL || di.dli_fbase == NULL) return false;

    const char *slash = strrchr(di.dli_fname, '/');
    const char *name = slash ? slash + 1 : di.dli_fname;

    uint64_t base = 0;
    if (!pd_remote_image_base(task, name, &base)) return false;

    *out = base + ((uint64_t)(uintptr_t)sym - (uint64_t)(uintptr_t)di.dli_fbase);
    return true;
}

#pragma mark - ARM64 桩

/*
 *  偏移  指令
 *   0    ldr  x8, #8          ; x8 = *(pc+8)  = dlopen
 *   8    <dlopen 地址>
 *  16    ldr  x9, #8          ; x9 = *(pc+8)  = pthread_exit
 *  24    <pthread_exit 地址>
 *  32    blr  x8              ; dlopen(x0=path, x1=RTLD_NOW)
 *  36    mov  x0, #0
 *  40    blr  x9              ; pthread_exit(NULL)，不返回
 *  44    b    .                ; 兜底自旋
 *
 *  注意：全部用普通 BLR，不用 BLRAA。被调函数自己的 PACIASP 会给 LR 签名，
 *  返回时的 AUTIASP 验的就是它自己签的那份，所以传裸地址不会触发 PAC 失败。
 */
static void pd_build_stub(uint8_t out[PD_STUB_SIZE], uint64_t dlopen_addr, uint64_t exit_addr) {
    memset(out, 0, PD_STUB_SIZE);
    uint32_t *w = (uint32_t *)out;

    w[0] = 0x58000048;                       /* ldr x8, #8 */
    *(uint64_t *)(out + 8) = dlopen_addr;
    w[4] = 0x58000049;                       /* ldr x9, #8 */
    *(uint64_t *)(out + 24) = exit_addr;
    w[8] = 0xD63F0100;                       /* blr x8 */
    w[9] = 0xD2800000;                       /* mov x0, #0 */
    w[10] = 0xD63F0120;                      /* blr x9 */
    w[11] = 0x14000000;                      /* b . */
}

#pragma mark - 对外接口

bool pd_can_attach(pid_t pid, char *err, size_t errlen) {
    mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) {
        pd_seterr(err, errlen,
                  "task_for_pid(%d) 失败: %s\n"
                  "需要：进程有 task_for_pid-allow 权限 + 越狱内核 proc_enforce=0；\n"
                  "或者目标 App 带 get-task-allow（调试签名）。",
                  pid, mach_error_string(kr));
        return false;
    }
    mach_port_deallocate(mach_task_self(), task);
    return true;
}

bool pd_image_loaded(pid_t pid, const char *needle) {
    mach_port_t task = MACH_PORT_NULL;
    if (task_for_pid(mach_task_self(), pid, &task) != KERN_SUCCESS) return false;

    struct task_dyld_info tdi;
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    bool found = false;

    if (task_info(task, TASK_DYLD_INFO, (task_info_t)&tdi, &count) == KERN_SUCCESS) {
        struct { uint32_t version; uint32_t n; uint64_t array; } hdr;
        if (pd_read(task, tdi.all_image_info_addr, &hdr, sizeof(hdr)) && hdr.n > 0 && hdr.n < 8192) {
            for (uint32_t i = 0; i < hdr.n && !found; i++) {
                struct { uint64_t addr; uint64_t path; uint64_t mod; } info;
                if (!pd_read(task, hdr.array + (uint64_t)i * 24, &info, sizeof(info))) continue;
                char path[512] = {0};
                if (!pd_read(task, info.path, path, sizeof(path) - 1)) continue;
                if (strstr(path, needle)) found = true;
            }
        }
    }
    mach_port_deallocate(mach_task_self(), task);
    return found;
}

bool pd_inject_dylib(pid_t pid, const char *dylib_path, char *err, size_t errlen) {
    if (pid <= 0 || !dylib_path || !*dylib_path) {
        pd_seterr(err, errlen, "参数不合法");
        return false;
    }

    mach_port_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS) {
        pd_seterr(err, errlen, "task_for_pid 失败: %s（见 README「注入权限」一节）",
                  mach_error_string(kr));
        return false;
    }

    bool ok = false;
    uint64_t path_addr = 0, stack_addr = 0, stub_addr = 0;
    thread_t th = MACH_PORT_NULL;
    bool stub_rx = false;

    do {
        uint64_t dlopen_addr = 0, exit_addr = 0;
        if (!pd_remote_symbol(task, (void *)dlopen, &dlopen_addr)) {
            pd_seterr(err, errlen, "在目标进程里找不到 libdyld.dylib（dyld 信息读不出来）");
            break;
        }
        if (!pd_remote_symbol(task, (void *)pthread_exit, &exit_addr)) {
            pd_seterr(err, errlen, "在目标进程里找不到 pthread_exit");
            break;
        }

        size_t plen = strlen(dylib_path) + 1;
        if (!pd_alloc(task, plen, &path_addr) || !pd_write(task, path_addr, dylib_path, plen)) {
            pd_seterr(err, errlen, "在目标进程里分配/写入路径失败");
            break;
        }

        if (!pd_alloc(task, PD_STACK_SIZE, &stack_addr)) {
            pd_seterr(err, errlen, "在目标进程里分配栈失败");
            break;
        }

        /* 先试桩（最干净）；拿不到可执行内存就退化 */
        if (pd_alloc(task, PD_STUB_SIZE, &stub_addr)) {
            uint8_t stub[PD_STUB_SIZE];
            pd_build_stub(stub, dlopen_addr, exit_addr);
            if (pd_write(task, stub_addr, stub, sizeof(stub))) {
                kr = mach_vm_protect(task, stub_addr, PD_STUB_SIZE, FALSE,
                                     VM_PROT_READ | VM_PROT_EXECUTE);
                stub_rx = (kr == KERN_SUCCESS);
            }
        }

        arm_thread_state64_t st;
        memset(&st, 0, sizeof(st));
        st.__x[0] = path_addr;
        st.__x[1] = RTLD_NOW;
        st.__sp = (stack_addr + PD_STACK_SIZE - 0x100) & ~0xFULL;
        st.__fp = 0;

        if (stub_rx) {
            st.__pc = stub_addr;
            st.__lr = stub_addr + 44;        /* 万一返回就自旋，绝不跳野地址 */
        } else {
            st.__pc = dlopen_addr;
            st.__lr = exit_addr;             /* dlopen 返回后直接 pthread_exit */
        }

        kr = thread_create_running(task, ARM_THREAD_STATE64,
                                   (thread_state_t)&st, ARM_THREAD_STATE64_COUNT, &th);
        if (kr != KERN_SUCCESS) {
            pd_seterr(err, errlen, "thread_create_running 失败: %s", mach_error_string(kr));
            break;
        }

        /* 等镜像出现：dlopen 成功就会进 dyld 的镜像表 */
        const char *base = strrchr(dylib_path, '/');
        base = base ? base + 1 : dylib_path;

        bool loaded = false;
        for (int i = 0; i < 50; i++) {       /* 最多 5 秒 */
            usleep(100 * 1000);
            if (pd_image_loaded(pid, base)) { loaded = true; break; }
        }

        if (!loaded) {
            pd_seterr(err, errlen,
                      "dlopen 没有生效。常见原因：\n"
                      "  · 目标 App 启用了库校验（App Store 签名），未签名 dylib 被拒\n"
                      "    → 越狱环境用 Dopamine 的 amfi 绕过，或改用静态注入（TrollFools）\n"
                      "  · dylib 路径目标进程读不到（沙盒）→ 先拷进目标的 Documents\n"
                      "  · dylib 架构不对（要 arm64 / arm64e）");
            break;
        }

        /* 让 dylib 的构造函数跑完再收尸 */
        usleep(300 * 1000);
        if (stub_rx && th != MACH_PORT_NULL) {
            thread_suspend(th);
            thread_terminate(th);
            th = MACH_PORT_NULL;
        }
        ok = true;
    } while (0);

    if (th != MACH_PORT_NULL) {
        thread_terminate(th);
    }
    if (path_addr) mach_vm_deallocate(task, path_addr, 4096);
    if (stack_addr) mach_vm_deallocate(task, stack_addr, PD_STACK_SIZE);
    if (stub_addr) mach_vm_deallocate(task, stub_addr, PD_STUB_SIZE);
    mach_port_deallocate(mach_task_self(), task);

    return ok;
}
