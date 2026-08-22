/*
 * stretchblt_dst_spy.c — runtime trampoline on win32u NtGdiStretchBlt.
 *
 * Classifies login-size StretchBlt destinations (WindowFromDC + type bits +
 * GetPixel samples on src/dst) without WINEDEBUG=+bitblt.
 *
 *   clang -arch x86_64 -dynamiclib -O2 -o Tools/bin/stretchblt_dst_spy.dylib \
 *       Tools/stretchblt_dst_spy.c \
 *       -isysroot $(xcrun --sdk macosx --show-sdk-path)
 *
 * Insert only on wine child:
 *   arch -x86_64 env DYLD_INSERT_LIBRARIES=.../stretchblt_dst_spy.dylib \
 *       STRETCHBLT_SPY_LOG=.../spy.log "$WINE" upc.exe …
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <libgen.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#ifndef PAGE_SIZE
#define PAGE_SIZE 4096
#endif

typedef int BOOL;
typedef unsigned long ULONG_PTR;
typedef ULONG_PTR HANDLE;
typedef HANDLE HDC;
typedef HANDLE HWND;
typedef unsigned int DWORD;
typedef int INT;
typedef DWORD COLORREF;

typedef BOOL (*NtGdiStretchBlt_fn)(HDC, INT, INT, INT, INT, HDC, INT, INT, INT, INT, DWORD, COLORREF);
typedef HWND (*NtUserWindowFromDC_fn)(HDC);
typedef COLORREF (*NtGdiGetPixel_fn)(HDC, INT, INT);

static NtGdiStretchBlt_fn real_stretch;
static NtUserWindowFromDC_fn p_WindowFromDC;
static NtGdiGetPixel_fn p_GetPixel;

static int spy_fd = -1;
static int agent_fd = -1;
static int hooked;
static int login_logs;
static char proc_label[256];

/* Trampoline storage: original prolog + jump back */
static uint8_t trampoline[64];
static uint8_t orig_bytes[16];
static void *hook_target;

#define NTGDI_HANDLE_TYPE_MASK 0x007f0000u
#define NTGDI_OBJ_DC           0x01u
#define NTGDI_OBJ_MEMDC        0x41u

static unsigned type_byte(ULONG_PTR h)
{
    return (unsigned)((h & NTGDI_HANDLE_TYPE_MASK) >> 16);
}

static const char *type_name(unsigned t)
{
    if (t == NTGDI_OBJ_DC) return "DC";
    if (t == NTGDI_OBJ_MEMDC) return "MEMDC";
    return "OTHER";
}

static void ensure_label(void)
{
    if (proc_label[0]) return;
    char path[1024];
    uint32_t sz = sizeof(path);
    const char *leaf = "?";
    if (_NSGetExecutablePath(path, &sz) == 0) {
        char *base = strrchr(path, '/');
        leaf = base ? base + 1 : path;
    }
    snprintf(proc_label, sizeof(proc_label), "pid=%d exe=%s", (int)getpid(), leaf);
}

static void fd_write_all(int fd, const char *buf, size_t n)
{
    while (n > 0) {
        ssize_t w = write(fd, buf, n);
        if (w <= 0) break;
        buf += (size_t)w;
        n -= (size_t)w;
    }
}

static void agent_log(const char *hypothesisId, const char *location, const char *message,
                      const char *data_json)
{
    /* #region agent log */
    char line[1024];
    int n;
    long long ts;
    if (agent_fd < 0) return;
    ts = (long long)time(NULL) * 1000LL;
    n = snprintf(line, sizeof(line),
                 "{\"sessionId\":\"505da6\",\"hypothesisId\":\"%s\",\"location\":\"%s\","
                 "\"message\":\"%s\",\"data\":%s,\"timestamp\":%lld}\n",
                 hypothesisId, location, message, data_json ? data_json : "{}", ts);
    if (n > 0)
        fd_write_all(agent_fd, line, (size_t)(n < (int)sizeof(line) ? n : (int)sizeof(line) - 1));
    /* #endregion */
}

static void spy_log(const char *fmt, ...)
{
    char buf[512];
    char line[640];
    va_list ap;
    int n, m;
    struct timespec ts;
    if (spy_fd < 0) return;
    ensure_label();
    clock_gettime(CLOCK_REALTIME, &ts);
    va_start(ap, fmt);
    n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n < 0) return;
    m = snprintf(line, sizeof(line), "%ld.%03ld [%s] %s",
                 (long)ts.tv_sec, ts.tv_nsec / 1000000L, proc_label, buf);
    if (m > 0)
        fd_write_all(spy_fd, line, (size_t)(m < (int)sizeof(line) ? m : (int)sizeof(line) - 1));
}

static int make_exec(void *addr, size_t len)
{
    uintptr_t page = (uintptr_t)addr & ~(uintptr_t)(PAGE_SIZE - 1);
    size_t span = ((uintptr_t)addr + len) - page + PAGE_SIZE;
    return mprotect((void *)page, span, PROT_READ | PROT_WRITE | PROT_EXEC);
}

/* x86_64: movabs rax,imm64; jmp rax  (12 bytes) */
static void emit_jmp(uint8_t *dst, void *to)
{
    dst[0] = 0x48;
    dst[1] = 0xb8;
    memcpy(dst + 2, &to, 8);
    dst[10] = 0xff;
    dst[11] = 0xe0;
}

static BOOL hooked_NtGdiStretchBlt(HDC hdcDst, INT xDst, INT yDst, INT widthDst, INT heightDst,
                                   HDC hdcSrc, INT xSrc, INT ySrc, INT widthSrc, INT heightSrc,
                                   DWORD rop, COLORREF bk_color)
{
    static __thread int in_hook;
    BOOL ret;
    int interesting = (widthDst >= 1400 && heightDst >= 900) ||
                      (widthSrc >= 1400 && heightSrc >= 900);

    if (in_hook)
        return real_stretch(hdcDst, xDst, yDst, widthDst, heightDst,
                            hdcSrc, xSrc, ySrc, widthSrc, heightSrc, rop, bk_color);

    in_hook = 1;
    ret = real_stretch(hdcDst, xDst, yDst, widthDst, heightDst,
                       hdcSrc, xSrc, ySrc, widthSrc, heightSrc, rop, bk_color);

    /* Log-only: NO WindowFromDC / GetPixel here — those coincided with Connect
     * dying on the first login-size blit. Handle type bits are enough for DC vs MEMDC;
     * hwnd was already proven 0x200aa on the one sampled run. */
    if (interesting && login_logs < 48) {
        unsigned st = type_byte((ULONG_PTR)hdcSrc);
        unsigned dt = type_byte((ULONG_PTR)hdcDst);
        char buf[512];

        login_logs++;
        ensure_label();
        spy_log("LOGIN_BLIT #%d ret=%d dst=%p(%s) src=%p(%s) "
                "dstWH=%dx%d srcWH=%dx%d xy=%d,%d rop=%08x\n",
                login_logs, (int)ret,
                (void *)hdcDst, type_name(dt),
                (void *)hdcSrc, type_name(st),
                widthDst, heightDst, widthSrc, heightSrc,
                xDst, yDst, (unsigned)rop);

        snprintf(buf, sizeof(buf),
                 "{\"proc\":\"%s\",\"n\":%d,\"ret\":%d,"
                 "\"dst\":\"%p\",\"dstType\":\"%s\",\"dstTypeByte\":%u,"
                 "\"src\":\"%p\",\"srcType\":\"%s\",\"srcTypeByte\":%u,"
                 "\"dstWH\":[%d,%d],\"srcWH\":[%d,%d],\"xy\":[%d,%d],\"rop\":%u}",
                 proc_label, login_logs, (int)ret,
                 (void *)hdcDst, type_name(dt), dt,
                 (void *)hdcSrc, type_name(st), st,
                 widthDst, heightDst, widthSrc, heightSrc, xDst, yDst, (unsigned)rop);
        agent_log("A-E", "stretchblt_dst_spy.c:hook", "login-size StretchBlt", buf);
    }
    in_hook = 0;
    return ret;
}

static int resolve_syms(void)
{
    void *h = dlopen(NULL, RTLD_NOW);
    /* Prefer already-loaded win32u via RTLD_DEFAULT after wine loads it;
     * constructor may run early — retry from hook path. */
    real_stretch = (NtGdiStretchBlt_fn)dlsym(RTLD_DEFAULT, "NtGdiStretchBlt");
    if (!real_stretch)
        real_stretch = (NtGdiStretchBlt_fn)dlsym(RTLD_DEFAULT, "_NtGdiStretchBlt");
    p_WindowFromDC = (NtUserWindowFromDC_fn)dlsym(RTLD_DEFAULT, "NtUserWindowFromDC");
    if (!p_WindowFromDC)
        p_WindowFromDC = (NtUserWindowFromDC_fn)dlsym(RTLD_DEFAULT, "_NtUserWindowFromDC");
    p_GetPixel = (NtGdiGetPixel_fn)dlsym(RTLD_DEFAULT, "NtGdiGetPixel");
    if (!p_GetPixel)
        p_GetPixel = (NtGdiGetPixel_fn)dlsym(RTLD_DEFAULT, "_NtGdiGetPixel");
    (void)h;
    return real_stretch != NULL;
}

static int install_hook(void)
{
    uint8_t *fn;
    if (hooked) return 1;
    if (!resolve_syms()) return 0;

    fn = (uint8_t *)(void *)real_stretch;
    hook_target = fn;
    memcpy(orig_bytes, fn, 12);

    /* Build trampoline: orig 12 bytes + jmp to fn+12 */
    memcpy(trampoline, orig_bytes, 12);
    emit_jmp(trampoline + 12, fn + 12);
    if (make_exec(trampoline, sizeof(trampoline)) != 0)
        return 0;
    real_stretch = (NtGdiStretchBlt_fn)(void *)trampoline;

    if (make_exec(fn, 16) != 0)
        return 0;
    emit_jmp(fn, (void *)hooked_NtGdiStretchBlt);
    hooked = 1;
    spy_log("hooked NtGdiStretchBlt @ %p trampoline=%p\n", fn, (void *)trampoline);
    agent_log("C", "stretchblt_dst_spy.c:install", "hook installed", "{\"ok\":1}");
    return 1;
}

/* Wine may load win32u after our constructor — poll + dyld image callback. */
static void *late_hook_thread(void *arg)
{
    int i;
    (void)arg;
    for (i = 0; i < 400 && !hooked; i++) {
        if (install_hook()) break;
        usleep(50000); /* 50ms * 400 = 20s */
    }
    if (!hooked)
        spy_log("FAILED to resolve/hook NtGdiStretchBlt after wait\n");
    return NULL;
}

static void on_add_image(const struct mach_header *mh, intptr_t slide)
{
    Dl_info info;
    (void)slide;
    if (hooked) return;
    if (!dladdr(mh, &info) || !info.dli_fname) return;
    if (!strstr(info.dli_fname, "win32u.so")) return;
    spy_log("win32u.so loaded: %s — installing hook\n", info.dli_fname);
    install_hook();
}

static void open_log_fds(void)
{
    const char *p = getenv("STRETCHBLT_SPY_LOG");
    if (spy_fd < 0) {
        spy_fd = open(p && *p ? p : "/tmp/stretchblt-dst-spy.log",
                      O_WRONLY | O_CREAT | O_APPEND, 0644);
    }
    if (agent_fd < 0) {
        agent_fd = open("/Users/ebenoelofse/Desktop/wyn/.cursor/debug-505da6.log",
                        O_WRONLY | O_CREAT | O_APPEND, 0644);
    }
}

__attribute__((constructor))
static void spy_init(void)
{
    pthread_t th;
    open_log_fds();
    ensure_label();
    spy_log("spy_init %s\n", proc_label);
    agent_log("C", "stretchblt_dst_spy.c:init", "spy_init", "{\"ok\":1}");
    _dyld_register_func_for_add_image(on_add_image);
    if (!install_hook()) {
        pthread_create(&th, NULL, late_hook_thread, NULL);
        pthread_detach(th);
    }
}
