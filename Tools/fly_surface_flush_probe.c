/*
 * fly_surface_flush_probe.c — log-only trampoline on window_surface_flush.
 *
 * Phase 2: classify frankea login gap (missing flush vs empty dirty vs wrong view).
 * DYLD_INTERPOSE fails (symbol not in flat namespace at insert time) — hook after
 * win32u.so loads via dyld add_image + entry trampoline.
 *
 *   clang -arch x86_64 -dynamiclib -O2 -o Tools/bin/fly_surface_flush_probe.dylib \
 *       Tools/fly_surface_flush_probe.c \
 *       -isysroot $(xcrun --sdk macosx --show-sdk-path)
 */
#include <dlfcn.h>
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

typedef int INT;
typedef unsigned long ULONG_PTR;
typedef ULONG_PTR HWND;

typedef struct {
    INT left, top, right, bottom;
} RECT;

struct fly_window_surface {
    void *funcs;
    void *entry_next;
    void *entry_prev;
    int ref;
    int pad_ref;
    HWND hwnd; /* 0x20 */
    RECT rect; /* 0x28 */
    char mutex_pad[0x40];
    RECT bounds; /* 0x78 */
    void *clip_region;
    unsigned draw_start_ticks;
    unsigned color_key;
    unsigned alpha_bits;
    unsigned alpha_mask;
};

#define HOOK_LEN 12 /* movabs rax, imm64; jmp rax — steals through push r12 */

static FILE *logfp;
static pthread_mutex_t logmu = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t install_mu = PTHREAD_MUTEX_INITIALIZER;
static char proc_label[256];
static unsigned flush_total;
static unsigned flush_loginish;
static unsigned flush_splashish;
static int hooked;
static uint8_t *flush_addr;
static uint8_t *cave_page;
static uint8_t orig_bytes[HOOK_LEN];

static void ensure_label(void)
{
    char path[1024];
    uint32_t sz = sizeof(path);
    const char *leaf = "?";
    if (proc_label[0])
        return;
    if (_NSGetExecutablePath(path, &sz) == 0) {
        leaf = strrchr(path, '/');
        leaf = leaf ? leaf + 1 : path;
    }
    snprintf(proc_label, sizeof(proc_label), "pid=%d exe=%s", (int)getpid(), leaf);
}

static void agent_log(const char *hid, const char *msg, const char *data_json)
{
    /* #region agent log */
    FILE *f = fopen("/Users/ebenoelofse/Desktop/wyn/.cursor/debug-b55dfe.log", "a");
    struct timespec ts;
    long long ms;
    if (!f)
        return;
    clock_gettime(CLOCK_REALTIME, &ts);
    ms = (long long)ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
    fprintf(f,
            "{\"sessionId\":\"b55dfe\",\"runId\":\"phase2-flush\",\"hypothesisId\":\"%s\","
            "\"location\":\"fly_surface_flush_probe.c\",\"message\":\"%s\",\"data\":%s,"
            "\"timestamp\":%lld}\n",
            hid ? hid : "?", msg ? msg : "?",
            (data_json && data_json[0]) ? data_json : "{}", ms);
    fclose(f);
    /* #endregion */
}

static void spy_log(const char *fmt, ...)
{
    char buf[512];
    char line[640];
    va_list ap;
    int n, m;
    struct timespec ts;
    const char *path;

    pthread_mutex_lock(&logmu);
    if (!logfp) {
        path = getenv("FLY_FLUSH_PROBE_LOG");
        if (!path || !path[0])
            path = "/tmp/fly-flush-probe.log";
        logfp = fopen(path, "a");
        if (logfp)
            setvbuf(logfp, NULL, _IOLBF, 0);
    }
    if (!logfp) {
        pthread_mutex_unlock(&logmu);
        return;
    }
    ensure_label();
    clock_gettime(CLOCK_REALTIME, &ts);
    va_start(ap, fmt);
    n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n < 0) {
        pthread_mutex_unlock(&logmu);
        return;
    }
    m = snprintf(line, sizeof(line), "%ld.%03ld [%s] %s", (long)ts.tv_sec,
                 ts.tv_nsec / 1000000L, proc_label, buf);
    if (m > 0)
        fputs(line, logfp);
    pthread_mutex_unlock(&logmu);
}

static int make_rwx(void *addr, size_t len)
{
    uintptr_t start = (uintptr_t)addr & ~(uintptr_t)(PAGE_SIZE - 1);
    uintptr_t end = ((uintptr_t)addr + len + PAGE_SIZE - 1) & ~(uintptr_t)(PAGE_SIZE - 1);
    return mprotect((void *)start, end - start, PROT_READ | PROT_WRITE | PROT_EXEC);
}

/* Called from trampoline with surface in rdi (System V). */
__attribute__((noinline)) void fly_after_flush_entry(struct fly_window_surface *surface)
{
    int rw, rh, bw, bh;
    int loginish = 0, splashish = 0;
    char j[384];

    if (!surface)
        return;

    rw = surface->rect.right - surface->rect.left;
    rh = surface->rect.bottom - surface->rect.top;
    bw = surface->bounds.right - surface->bounds.left;
    bh = surface->bounds.bottom - surface->bounds.top;
    if (rw >= 1400 && rh >= 650)
        loginish = 1;
    if (rw >= 700 && rw <= 900 && rh >= 400 && rh <= 600)
        splashish = 1;
    flush_total++;
    if (loginish)
        flush_loginish++;
    if (splashish)
        flush_splashish++;

    spy_log("FLUSH hwnd=%p surface=%p rect=%dx%d bounds=%dx%d "
            "alpha_bits=%u alpha_mask=%u loginish=%d splashish=%d total=%u\n",
            (void *)surface->hwnd, (void *)surface, rw, rh, bw, bh, surface->alpha_bits,
            surface->alpha_mask, loginish, splashish, flush_total);

    /* #region agent log */
    if (loginish || splashish || (flush_total <= 8) || (flush_total % 25 == 0)) {
        snprintf(j, sizeof(j),
                 "{\"hwnd\":\"%p\",\"rect\":[%d,%d],\"bounds\":[%d,%d],"
                 "\"alpha_bits\":%u,\"alpha_mask\":%u,\"loginish\":%d,"
                 "\"splashish\":%d,\"total\":%u,\"loginish_n\":%u,\"splashish_n\":%u}",
                 (void *)surface->hwnd, rw, rh, bw, bh, surface->alpha_bits, surface->alpha_mask,
                 loginish, splashish, flush_total, flush_loginish, flush_splashish);
        agent_log(loginish ? "F1" : (splashish ? "F2" : "F3"), "window_surface_flush", j);
    }
    /* #endregion */
}

static int install_flush_hook(void)
{
    uint8_t *fn;
    uint8_t *cave;
    int off = 0;
    void *cont;

    pthread_mutex_lock(&install_mu);
    if (hooked) {
        pthread_mutex_unlock(&install_mu);
        return 1;
    }

    fn = (uint8_t *)dlsym(RTLD_DEFAULT, "window_surface_flush");
    if (!fn)
        fn = (uint8_t *)dlsym(RTLD_DEFAULT, "_window_surface_flush");
    if (!fn) {
        pthread_mutex_unlock(&install_mu);
        return 0;
    }

    /* Expected prologue: push rbp; mov rbp,rsp; push r15... */
    if (!(fn[0] == 0x55 && fn[1] == 0x48 && fn[2] == 0x89 && fn[3] == 0xe5)) {
        spy_log("UNEXPECTED flush prologue @ %p: %02x%02x%02x%02x\n", (void *)fn, fn[0], fn[1],
                fn[2], fn[3]);
        agent_log("F1", "flush hook unexpected prologue", "{\"ok\":0}");
        pthread_mutex_unlock(&install_mu);
        return 0;
    }

    flush_addr = fn;
    memcpy(orig_bytes, fn, HOOK_LEN);

    cave_page = mmap(NULL, PAGE_SIZE, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1,
                     0);
    if (cave_page == MAP_FAILED) {
        cave_page = NULL;
        pthread_mutex_unlock(&install_mu);
        return 0;
    }
    cave = cave_page;
    memset(cave, 0x90, PAGE_SIZE);

    /* Preserve rdi (surface); call logger; run stolen bytes; jmp to fn+HOOK_LEN. */
    cave[off++] = 0x50; /* push rax */
    cave[off++] = 0x51;
    cave[off++] = 0x52;
    cave[off++] = 0x56;
    cave[off++] = 0x57;
    cave[off++] = 0x41;
    cave[off++] = 0x50;
    cave[off++] = 0x41;
    cave[off++] = 0x51;
    cave[off++] = 0x48;
    cave[off++] = 0xb8; /* movabs rax, imm */
    {
        void *fp = (void *)fly_after_flush_entry;
        memcpy(cave + off, &fp, 8);
        off += 8;
    }
    cave[off++] = 0xff;
    cave[off++] = 0xd0; /* call rax — rdi still = surface */
    cave[off++] = 0x41;
    cave[off++] = 0x59;
    cave[off++] = 0x41;
    cave[off++] = 0x58;
    cave[off++] = 0x5f;
    cave[off++] = 0x5e;
    cave[off++] = 0x5a;
    cave[off++] = 0x59;
    cave[off++] = 0x58;
    memcpy(cave + off, orig_bytes, HOOK_LEN);
    off += HOOK_LEN;
    cave[off++] = 0x48;
    cave[off++] = 0xb8;
    cont = fn + HOOK_LEN;
    memcpy(cave + off, &cont, 8);
    off += 8;
    cave[off++] = 0xff;
    cave[off++] = 0xe0; /* jmp rax */

    if (make_rwx(fn, HOOK_LEN) != 0) {
        spy_log("mprotect flush failed\n");
        agent_log("F1", "flush hook mprotect fail", "{\"ok\":0}");
        pthread_mutex_unlock(&install_mu);
        return 0;
    }

    /* Absolute jmp to cave at function entry. */
    fn[0] = 0x48;
    fn[1] = 0xb8;
    {
        void *c = cave;
        memcpy(fn + 2, &c, 8);
    }
    fn[10] = 0xff;
    fn[11] = 0xe0;

    hooked = 1;
    spy_log("flush hook installed @ %p cave=%p\n", (void *)fn, (void *)cave);
    agent_log("F1", "flush hook installed", "{\"ok\":1}");
    pthread_mutex_unlock(&install_mu);
    return 1;
}

static void on_add_image(const struct mach_header *mh, intptr_t slide)
{
    Dl_info info;
    (void)slide;
    if (hooked)
        return;
    if (!dladdr(mh, &info) || !info.dli_fname)
        return;
    if (!strstr(info.dli_fname, "win32u.so"))
        return;
    install_flush_hook();
}

__attribute__((constructor)) static void fly_flush_probe_init(void)
{
    agent_log("F1", "flush probe load", "{\"bridge\":0}");
    spy_log("flush probe load\n");
    _dyld_register_func_for_add_image(on_add_image);
    /* win32u may already be loaded */
    install_flush_hook();
}
