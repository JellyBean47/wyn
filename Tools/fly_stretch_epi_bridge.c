/*
 * fly_stretch_epi_bridge.c — hook NtGdiStretchBlt EPILOGUE only (not entry).
 *
 * HANDOFF: entry DYLD trampoline on NtGdiStretchBlt kills Connect.
 * Post-blit epilogue sees login-size presents after the real blit returns.
 *
 * Unix-side only: frankea has x86_64-unix/win32u.so and no i386-unix win32u.
 * Connect upc.exe is PE32 and EADesktop.exe is PE32+; both thunk into the
 * same NtGdiStretchBlt (epilogue +0x33c, frame hdc @ rbp-0x120/-0x118,
 * bitblt_coords src @ rbp-0xcc / dst @ rbp-0x98). Do not inject this
 * x86_64 dylib into an arm64 wine; do not build a 32-bit dylib.
 *
 * Parent PeekMessage process: upc.exe or EADesktop.exe.
 * Producer (StretchBlt): UplayWebCore / EACefSubProcess / in-process GPU.
 * EA shm defaults to FLY_BRIDGE_SHM4_NAME=/fly-ea-stretch-bridge4 so a
 * Connect session on the Steam bottle is never unlinked.
 *
 *   clang -arch x86_64 -dynamiclib -O2 -o Tools/bin/fly_stretch_epi_bridge.fast.dylib \
 *       Tools/fly_stretch_epi_bridge.c \
 *       -isysroot $(xcrun --sdk macosx --show-sdk-path)
 */
#define _GNU_SOURCE
#include <crt_externs.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#ifndef PAGE_SIZE
#define PAGE_SIZE 4096
#endif

typedef unsigned long ULONG_PTR;
typedef ULONG_PTR HANDLE;
typedef HANDLE HDC;
typedef HANDLE HBITMAP;
typedef HANDLE HWND;
typedef HANDLE HRGN;
typedef unsigned int DWORD;
typedef unsigned int UINT;
typedef int INT;
typedef int BOOL;

typedef struct {
    INT left, top, right, bottom;
} RECT;

#pragma pack(push, 1)
typedef struct {
    unsigned biSize;
    int biWidth;
    int biHeight;
    unsigned short biPlanes;
    unsigned short biBitCount;
    unsigned biCompression;
    unsigned biSizeImage;
    int biXPelsPerMeter;
    int biYPelsPerMeter;
    unsigned biClrUsed;
    unsigned biClrImportant;
} BITMAPINFOHEADER;
typedef struct {
    BITMAPINFOHEADER bmiHeader;
} BITMAPINFO;
#pragma pack(pop)

typedef HDC (*NtGdiCreateCompatibleDC_fn)(HDC);
typedef HBITMAP (*NtGdiCreateDIBSection_fn)(HDC, void *, DWORD, void *, unsigned, unsigned, unsigned,
                                            unsigned long long, void **);
typedef HBITMAP (*NtGdiSelectBitmap_fn)(HDC, HBITMAP);
typedef BOOL (*NtGdiBitBlt_fn)(HDC, INT, INT, INT, INT, HDC, INT, INT, DWORD, DWORD, DWORD);
typedef BOOL (*NtGdiDeleteObjectApp_fn)(HANDLE);
typedef BOOL (*NtGdiDeleteDC_fn)(HDC);
typedef HWND (*NtUserWindowFromDC_fn)(HDC);
typedef HDC (*NtUserGetDC_fn)(HWND);
typedef HDC (*NtUserGetDCEx_fn)(HWND, HRGN, DWORD);
typedef INT (*NtUserReleaseDC_fn)(HWND, HDC);
typedef INT (*NtGdiSetDIBitsToDeviceInternal_fn)(HDC, INT, INT, DWORD, DWORD, INT, INT, UINT, UINT,
                                                 const void *, const BITMAPINFO *, UINT, UINT, UINT,
                                                 BOOL, HANDLE);
typedef void (*flush_window_surfaces_fn)(BOOL);

#define DCX_CLIPSIBLINGS 0x00000010u
#define DIB_RGB_COLORS 0u
#define EPI_OFF_FROM_STRETCH 0x33c
#define EPI_LEN 21

static const uint8_t EPI_ORIG[EPI_LEN] = {
    0x44, 0x89, 0xF0, 0x48, 0x81, 0xC4, 0xF8, 0x00, 0x00, 0x00, 0x5B, 0x41, 0x5C,
    0x41, 0x5D, 0x41, 0x5E, 0x41, 0x5F, 0x5D, 0xC3
};

/* Wine keeps both blit rectangles as `struct bitblt_coords` in the NtGdiStretchBlt
 * frame and hands them to the driver blit — verified in wine-11.0 win32u.so at
 * +0x305 (`lea -0xcc(%rbp),%rcx` src, `lea -0x98(%rbp),%rsi` dst). The epilogue
 * hook runs before `pop rbp`, so the whole frame is still live and unclobbered. */
struct blt_coords {
    int log_x, log_y, log_width, log_height; /* as the caller passed them */
    int x, y, width, height;                 /* mapped to device units */
    RECT visrect;                            /* clipped to the visible part */
    int layout;
};

#define FRAME_HDC_DST 0x120
#define FRAME_HDC_SRC 0x118
#define FRAME_SRC_COORDS 0xcc
#define FRAME_DST_COORDS 0x98

static int spy_fd = -1;
static pthread_mutex_t install_mu = PTHREAD_MUTEX_INITIALIZER;
static int hooked;
static int login_logs;
static int dumps_done;
static int dumps_written;
static unsigned best_unique;
static int live_mode; /* after first good frame: keep refreshing for typing caret */
static long long last_live_ms;
static unsigned last_frame_sig;
static int pin_w, pin_h; /* sticky dump size — thrash caused transparent regression */
static uint32_t *pin_buf; /* retained pin-sized frame for dirty-rect composite */
static int pin_buf_w, pin_buf_h;
static unsigned size_skip_total;
static unsigned nest_skip_total;
static unsigned nest_skip_sec;
static unsigned composite_sec;
static int any_logs;
static char proc_label[256];
static uint8_t *epi_addr;
static uint8_t *cave_page;
static HWND login_hwnd;
static unsigned epi_login_total;
static unsigned dump_write_total;
static unsigned identical_skip_total;
static unsigned epi_login_sec;
static unsigned dump_write_sec;
static unsigned size_skip_sec;
static unsigned gate_skip_sec;   /* large epi not login_like and not pinned */
static unsigned throttle_skip_sec;
static unsigned ident_skip_sec;
static long long rate_bucket_ms;
static unsigned option_b_sec;
static unsigned option_b_total;
static unsigned option_b_blit_ok;
static unsigned option_b_dib_ok;
static unsigned option_b_flush_ok;
static long long last_option_b_ms;
static int option_b_env = -1; /* -1 unset, 0 off, 1 on */
static int option_b_flush_env = -1;
static int parent_present_env = -1;
static int upc_process_cached = -1;
static int peek_hooked;
static uint8_t *peek_addr;
static uint8_t *peek_cave_page;
static uint8_t peek_stolen[16];
static long last_parent_mtime_ns;
static long long last_parent_present_ms;
static unsigned parent_present_ok;
static unsigned parent_present_fail;
static unsigned any_sub_sec; /* sub-window StretchBlt count/sec (scroll may tile small) */

/* #region agent log — debug-mode NDJSON (scroll-lag investigation) */
static void fd_write_all(int fd, const char *buf, size_t n);
static int dbg_fd = -1; /* -1 unopened, -2 disabled */
static void dbg_log(const char *hyp, const char *loc, const char *msg, const char *data_json)
{
    char line[900];
    struct timespec ts;
    const char *run;
    int m;
    if (dbg_fd == -2) return;
    if (dbg_fd < 0) {
        const char *p = getenv("FLY_DEBUG_LOG");
        if (!p || !*p) p = "/Users/ebenoelofse/Desktop/wyn/.cursor/debug-16dd6c.log";
        dbg_fd = open(p, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (dbg_fd < 0) { dbg_fd = -2; return; }
    }
    run = getenv("FLY_DEBUG_RUN");
    if (!run || !*run) run = "scroll";
    clock_gettime(CLOCK_REALTIME, &ts);
    m = snprintf(line, sizeof(line),
                 "{\"sessionId\":\"16dd6c\",\"runId\":\"%s\",\"hypothesisId\":\"%s\","
                 "\"location\":\"%s\",\"message\":\"%s\",\"data\":%s,\"pid\":%d,"
                 "\"timestamp\":%lld}\n",
                 run, hyp, loc, msg, data_json ? data_json : "{}", (int)getpid(),
                 (long long)ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL);
    if (m > 0)
        fd_write_all(dbg_fd, line, (size_t)(m < (int)sizeof(line) ? m : (int)sizeof(line) - 1));
}
/* #endregion */

static NtGdiCreateCompatibleDC_fn p_CreateCompatibleDC;
static NtGdiCreateDIBSection_fn p_CreateDIBSection;
static NtGdiSelectBitmap_fn p_SelectBitmap;
static NtGdiBitBlt_fn p_BitBlt;
static NtGdiDeleteObjectApp_fn p_DeleteObject;
static NtGdiDeleteDC_fn p_DeleteDC;
static NtUserWindowFromDC_fn p_WindowFromDC;
static NtUserGetDC_fn p_GetDC;
static NtUserGetDCEx_fn p_GetDCEx;
static NtUserReleaseDC_fn p_ReleaseDC;
static NtGdiSetDIBitsToDeviceInternal_fn p_SetDIBits;
static flush_window_surfaces_fn p_flush_window_surfaces;

static long long now_ms_mono(void);
static void resolve_flush_window_surfaces(void);

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
    (void)hypothesisId;
    (void)location;
    (void)message;
    (void)data_json;
}

static void spy_log(const char *fmt, ...)
{
    char buf[512];
    char line[640];
    va_list ap;
    int n, m;
    struct timespec ts;
    if (spy_fd < 0) return;
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

static void ensure_label(void)
{
    char path[1024];
    uint32_t sz = sizeof(path);
    const char *leaf = "?";
    if (proc_label[0]) return;
    if (_NSGetExecutablePath(path, &sz) == 0) {
        char *base = strrchr(path, '/');
        leaf = base ? base + 1 : path;
    }
    snprintf(proc_label, sizeof(proc_label), "pid=%d exe=%s", (int)getpid(), leaf);
}

static int make_rwx(void *addr, size_t len)
{
    uintptr_t page = (uintptr_t)addr & ~(uintptr_t)(PAGE_SIZE - 1);
    size_t span = ((uintptr_t)addr + len) - page + PAGE_SIZE;
    return mprotect((void *)page, span, PROT_READ | PROT_WRITE | PROT_EXEC);
}

static void emit_jmp(uint8_t *dst, void *to)
{
    dst[0] = 0x48;
    dst[1] = 0xb8;
    memcpy(dst + 2, &to, 8);
    dst[10] = 0xff;
    dst[11] = 0xe0;
}

static const char *bridge_path(void)
{
    const char *p = getenv("PRESENT_BRIDGE_BGRA");
    if (p && *p) return p;
    return "/Users/ebenoelofse/Library/Containers/com.fly.gaming/Bottles/"
           "32050D6B-F756-491C-8CBF-8C4CAC1B5ECF/drive_c/windows/temp/fly-stretch-bridge.bgra";
}

/* v2 header: 'F''L''Y''2' + w + h + hwnd64 — parent upc needs hwnd for SetDIBits. */
#define BRIDGE_MAGIC_V2 0x32594C46u /* bytes F L Y 2 */
/* v3 POSIX shm: same fields + seq/ready — avoids per-frame file rewrite. */
#define BRIDGE_MAGIC_V3 0x33594C46u /* bytes F L Y 3 */
#define BRIDGE_SHM_NAME "/fly-upc-stretch-bridge"
#define BRIDGE_SHM_MAX_W 2048
#define BRIDGE_SHM_MAX_H 1200
#define BRIDGE_SHM_HDR 32
#define BRIDGE_SHM_BYTES (BRIDGE_SHM_HDR + (size_t)BRIDGE_SHM_MAX_W * (size_t)BRIDGE_SHM_MAX_H * 4)

#pragma pack(push, 1)
struct fly_bridge_shm {
    uint32_t magic;
    int32_t w;
    int32_t h;
    uint32_t seq;
    uint64_t hwnd64;
    uint32_t ready;
    uint32_t pad;
    /* uint8_t pixels[] follows */
};
#pragma pack(pop)

static int bridge_shm_env = -1;  /* -1 unset, 0 off, 1 on */
static int bridge_file_env = -1; /* keep .bgra for Cocoa bridge fallback */
static void *bridge_shm_map;
static size_t bridge_shm_map_bytes;
static int bridge_shm_fd = -1;
static uint32_t last_parent_shm_seq;

static int bridge_shm_enabled(void)
{
    const char *e;
    if (bridge_shm_env < 0) {
        e = getenv("FLY_BRIDGE_SHM");
        /* Default ON — parent-native path prefers shm; set 0 to force file-only. */
        bridge_shm_env = (!e || !e[0] || e[0] == '1') ? 1 : 0;
    }
    return bridge_shm_env;
}

static int bridge_file_enabled(void)
{
    const char *e;
    if (bridge_file_env < 0) {
        e = getenv("FLY_BRIDGE_FILE");
        /* Default ON so Cocoa login-bridge fallback still works. */
        bridge_file_env = (!e || !e[0] || e[0] == '1') ? 1 : 0;
    }
    return bridge_file_env;
}

static struct fly_bridge_shm *bridge_shm_ensure(int create)
{
    int fd;
    void *p;
    if (bridge_shm_map)
        return (struct fly_bridge_shm *)bridge_shm_map;
    if (!bridge_shm_enabled())
        return NULL;
    fd = shm_open(BRIDGE_SHM_NAME, create ? (O_CREAT | O_RDWR) : O_RDWR, 0666);
    if (fd < 0)
        return NULL;
    if (create) {
        if (ftruncate(fd, (off_t)BRIDGE_SHM_BYTES) != 0) {
            close(fd);
            return NULL;
        }
    }
    p = mmap(NULL, BRIDGE_SHM_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (p == MAP_FAILED) {
        close(fd);
        return NULL;
    }
    bridge_shm_fd = fd;
    bridge_shm_map = p;
    bridge_shm_map_bytes = BRIDGE_SHM_BYTES;
    return (struct fly_bridge_shm *)p;
}

static int bridge_shm_write(int w, int h, uint64_t hwnd64, const void *pixels)
{
    struct fly_bridge_shm *sh;
    size_t nbytes;
    uint8_t *dst;

    if (w < 8 || h < 8 || w > BRIDGE_SHM_MAX_W || h > BRIDGE_SHM_MAX_H || !pixels)
        return -1;
    sh = bridge_shm_ensure(1);
    if (!sh)
        return -1;
    nbytes = (size_t)w * (size_t)h * 4;
    sh->ready = 0;
    __sync_synchronize();
    sh->magic = BRIDGE_MAGIC_V3;
    sh->w = w;
    sh->h = h;
    sh->hwnd64 = hwnd64;
    dst = (uint8_t *)sh + BRIDGE_SHM_HDR;
    memcpy(dst, pixels, nbytes);
    sh->seq = sh->seq + 1;
    if (sh->seq == 0)
        sh->seq = 1;
    __sync_synchronize();
    sh->ready = 1;
    return 0;
}

/* Returns 1 if a new frame was copied into *bits_out (caller frees). */
static int bridge_shm_read_new(uint32_t *seq_io, int *w_out, int *h_out, uint64_t *hwnd_out,
                               void **bits_out)
{
    struct fly_bridge_shm *sh;
    size_t nbytes;
    void *bits;
    uint32_t seq;
    int w, h;

    *bits_out = NULL;
    sh = bridge_shm_ensure(0);
    if (!sh)
        return 0;
    if (sh->magic != BRIDGE_MAGIC_V3 || !sh->ready)
        return 0;
    seq = sh->seq;
    if (seq == 0 || seq == *seq_io)
        return 0;
    w = sh->w;
    h = sh->h;
    if (w < 8 || h < 8 || w > BRIDGE_SHM_MAX_W || h > BRIDGE_SHM_MAX_H || !sh->hwnd64)
        return 0;
    nbytes = (size_t)w * (size_t)h * 4;
    bits = malloc(nbytes);
    if (!bits)
        return 0;
    memcpy(bits, (uint8_t *)sh + BRIDGE_SHM_HDR, nbytes);
    /* Re-check seq didn't tear mid-copy */
    __sync_synchronize();
    if (sh->seq != seq || !sh->ready) {
        free(bits);
        return 0;
    }
    *seq_io = seq;
    *w_out = w;
    *h_out = h;
    *hwnd_out = sh->hwnd64;
    *bits_out = bits;
    return 1;
}

/* Full-width / near-full login presents (e.g. 1454×771) — proven live while pin is
 * 1454×934. */
static int near_pin_ok(int w, int h)
{
    if (pin_w <= 0 || pin_h <= 0) return 0;
    if (w < 1400 || h < 650) return 0;
    if (w > pin_w + 16 || h > pin_h + 16) return 0;
    if (w < pin_w - 32) return 0;
    return 1;
}

/* Small dirty strips only (e.g. 1068×291 typing/caret). */
static int mid_dirty_ok(int w, int h)
{
    long area, pin_area;
    if (!live_mode || pin_w <= 0 || pin_h <= 0 || !pin_buf) return 0;
    if (near_pin_ok(w, h)) return 0;
    if (w < 800 || h < 80 || h > 350 || w > pin_w || h > pin_h) return 0;
    area = (long)w * (long)h;
    pin_area = (long)pin_w * (long)pin_h;
    if (area < 40000L || area > pin_area * 25 / 100) return 0;
    return 1;
}

/* Large partial presents (1092×797 @ 281,137 / 1332×560 @ 17,211) — always reject.
 * Dest-composite stacked chrome headers on hover; scale-replace pulsed size.
 * Hover ghosts clear when the next near/full pin write lands (user-observed). */
static int mid_replace_ok(int w, int h)
{
    (void)w;
    (void)h;
    return 0;
}

static void scale_bgra_nn(const uint32_t *src, int sw, int sh, uint32_t *dst, int dw, int dh)
{
    int x, y;
    for (y = 0; y < dh; y++) {
        int sy = (int)((long)y * sh / dh);
        if (sy >= sh) sy = sh - 1;
        for (x = 0; x < dw; x++) {
            int sx = (int)((long)x * sw / dw);
            if (sx >= sw) sx = sw - 1;
            dst[y * dw + x] = src[sy * sw + sx];
        }
    }
}

static void ensure_pin_buf(void)
{
    if (pin_w <= 0 || pin_h <= 0) return;
    if (pin_buf && pin_buf_w == pin_w && pin_buf_h == pin_h) return;
    free(pin_buf);
    pin_buf = (uint32_t *)calloc((size_t)pin_w * (size_t)pin_h, 4);
    pin_buf_w = pin_w;
    pin_buf_h = pin_h;
}

static void blit_to_pin(const uint32_t *src, int sw, int sh, int dx, int dy, int dw, int dh)
{
    int x, y;
    if (!pin_buf || dw < 1 || dh < 1 || sw < 1 || sh < 1) return;
    for (y = 0; y < dh; y++) {
        int py = dy + y;
        int sy;
        if (py < 0 || py >= pin_h) continue;
        sy = (int)((long)y * sh / dh);
        if (sy >= sh) sy = sh - 1;
        for (x = 0; x < dw; x++) {
            int px = dx + x;
            int sx;
            if (px < 0 || px >= pin_w) continue;
            sx = (int)((long)x * sw / dw);
            if (sx >= sw) sx = sw - 1;
            pin_buf[py * pin_w + px] = src[sy * sw + sx];
        }
    }
}

/* Returns dump_rc; sets nz_out / nonbg_out. Writes bridge only when frame has
 * enough non-background pixels (dump4 was ~244 speckles on #0d0d0d — rejected).
 * composite=1: blit dirty SRC into retained pin_buf at (xDst,yDst). */
static int dump_src_bgra(HDC hdcSrc, int w, int h, int xDst, int yDst, int wDst, int hDst,
                         int composite, unsigned *nz_out, unsigned *nonbg_out)
{
    BITMAPINFO bmi;
    HDC mem = 0;
    HBITMAP dib = 0, old = 0;
    void *bits = NULL;
    unsigned nz = 0;
    unsigned nonbg = 0;
    int i, n, rc = -1;
    int fd;
    int wrote_ok = 0;
    size_t out_bytes = 0;
    char hdr[20];
    uint32_t bg;
    uint32_t magic;
    uint64_t hwnd64;

    *nz_out = 0;
    if (nonbg_out) *nonbg_out = 0;
    if (!hdcSrc || w < 8 || h < 8 || w > 4096 || h > 4096) return -1;
    if (!p_CreateCompatibleDC || !p_CreateDIBSection || !p_SelectBitmap || !p_BitBlt) return -2;

    memset(&bmi, 0, sizeof(bmi));
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = w;
    bmi.bmiHeader.biHeight = -h;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = 0;

    /* #region agent log */
    if (!composite || (dumps_done & 31) == 0) {
        char j[288];
        snprintf(j, sizeof(j),
                 "{\"src\":\"%p\",\"w\":%d,\"h\":%d,\"dstXY\":[%d,%d],\"dstWH\":[%d,%d],"
                 "\"composite\":%d}",
                 (void *)hdcSrc, w, h, xDst, yDst, wDst, hDst, composite);
        agent_log("F", "fly_stretch_epi_bridge.c:dump_enter", "dump_src_bgra enter", j);
    }
    /* #endregion */

    mem = p_CreateCompatibleDC(hdcSrc);
    if (!mem) return -3;
    dib = p_CreateDIBSection(mem, NULL, 0, &bmi, 0, 0, 0, 0, &bits);
    if (!dib || !bits) {
        /* #region agent log */
        {
            char j[128];
            snprintf(j, sizeof(j), "{\"dib\":\"%p\",\"bits\":\"%p\"}", (void *)dib, bits);
            agent_log("B", "fly_stretch_epi_bridge.c:dib_fail", "CreateDIBSection failed", j);
        }
        /* #endregion */
        if (p_DeleteDC) p_DeleteDC(mem);
        return -4;
    }
    old = p_SelectBitmap(mem, dib);
    if (!p_BitBlt(mem, 0, 0, w, h, hdcSrc, 0, 0, 0x00CC0020u, 0, 0)) {
        /* #region agent log */
        agent_log("B", "fly_stretch_epi_bridge.c:bitblt_fail", "BitBlt from SRC failed", "{\"rc\":-5}");
        /* #endregion */
        rc = -5;
        goto out;
    }
    n = w * h;
    bg = ((uint32_t *)bits)[0] & 0x00FFFFFFu;
    for (i = 0; i < n; i++) {
        uint32_t rgb = ((uint32_t *)bits)[i] & 0x00FFFFFFu;
        if (rgb) nz++;
        if (rgb != bg) nonbg++;
    }
    *nz_out = nz;
    if (nonbg_out) *nonbg_out = nonbg;

    /* Full-frame needs rich UI; dirty-rect composite can be smaller (field/caret). */
    if (nz == 0 || nonbg < (composite ? 200u : 5000u)) {
        rc = 0;
        /* #region agent log */
        {
            char j[192];
            snprintf(j, sizeof(j),
                     "{\"dump_rc\":0,\"nz\":%u,\"nonbg\":%u,\"bg\":\"0x%06x\",\"wrote\":0,"
                     "\"w\":%d,\"h\":%d,\"composite\":%d}",
                     nz, nonbg, (unsigned)bg, w, h, composite);
            agent_log(nz == 0 ? "C" : "I", "fly_stretch_epi_bridge.c:dump_skip",
                      "SRC dump skipped (empty/near-solid)", j);
        }
        /* #endregion */
        goto out;
    }

    if (!composite && pin_w && pin_h && (w != pin_w || h != pin_h)) {
        long area = (long)w * (long)h;
        long pin_area = (long)pin_w * (long)pin_h;
        int upgrade = (area > pin_area * 11 / 10) && w >= 1400 && h >= 900;
        int near = near_pin_ok(w, h);
        int replace = mid_replace_ok(w, h);
        if (!upgrade && !near && !replace) {
            size_skip_total++;
            size_skip_sec++;
            rc = 0;
            /* #region agent log */
            {
                char j[192];
                snprintf(j, sizeof(j),
                         "{\"w\":%d,\"h\":%d,\"pin\":[%d,%d],\"skip\":%u}",
                         w, h, pin_w, pin_h, size_skip_total);
                agent_log("G", "fly_stretch_epi_bridge.c:size_skip",
                          "SRC dump skipped (size thrash)", j);
                if ((size_skip_sec & 15u) == 1u)
                    dbg_log("H4", "fly_stretch_epi_bridge.c:size_skip",
                            "passed gate but size!=pin -> dropped", j);
            }
            /* #endregion */
            goto out;
        }
        if (upgrade) {
            pin_w = w;
            pin_h = h;
        }
    }

    /* Sig over SRC samples — dirty rects change here while full-frame edges stay still. */
    {
        unsigned sig = 2166136261u;
        int x0 = w / 5, x1 = (4 * w) / 5, y0 = h / 5, y1 = (4 * h) / 5;
        int x, y;
        if (composite) {
            x0 = 0;
            x1 = w;
            y0 = 0;
            y1 = h;
        }
        for (y = y0; y < y1; y += 2) {
            for (x = x0; x < x1; x += 2) {
                uint32_t px = ((uint32_t *)bits)[y * w + x];
                sig ^= px;
                sig *= 16777619u;
            }
        }
        sig ^= (unsigned)n ^ (unsigned)nonbg ^ (unsigned)xDst ^ (unsigned)yDst;
        if (live_mode && sig == last_frame_sig) {
            identical_skip_total++;
            ident_skip_sec++;
            rc = 0;
            goto out;
        }
        last_frame_sig = sig;
    }

    if (!pin_w) {
        pin_w = w;
        pin_h = h;
    }
    ensure_pin_buf();
    if (!pin_buf) {
        rc = -7;
        goto out;
    }

    if (composite) {
        /* Small dirty strips only — 1:1 into dest (ignore StretchBlt dst size). */
        (void)wDst;
        (void)hDst;
        blit_to_pin((const uint32_t *)bits, w, h, xDst, yDst, w, h);
        composite_sec++;
    } else if (w == pin_w && h == pin_h) {
        memcpy(pin_buf, bits, (size_t)pin_w * (size_t)pin_h * 4);
    } else {
        /* Near-pin / partial: pad-blit 1:1, keep remainder of pin (no stretch). */
        blit_to_pin((const uint32_t *)bits, w, h, xDst, yDst, w, h);
    }

    fd = -1;
    magic = BRIDGE_MAGIC_V2;
    hwnd64 = (uint64_t)(uintptr_t)login_hwnd;
    memcpy(hdr, &magic, 4);
    memcpy(hdr + 4, &pin_w, 4);
    memcpy(hdr + 8, &pin_h, 4);
    memcpy(hdr + 12, &hwnd64, 8);
    out_bytes = 20 + (size_t)pin_w * (size_t)pin_h * 4;

    /* Prefer POSIX shm for parent present (no per-frame file rewrite). */
    if (bridge_shm_write(pin_w, pin_h, hwnd64, pin_buf) == 0) {
        if ((dumps_written & 7) == 1)
            spy_log("BRIDGE_SHM wrote %dx%d hwnd=%p seq bytes=%zu\n",
                    pin_w, pin_h, (void *)login_hwnd, out_bytes);
        wrote_ok = 1;
    }

    if (bridge_file_enabled()) {
        fd = open(bridge_path(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (fd >= 0) {
            fd_write_all(fd, hdr, 20);
            fd_write_all(fd, (const char *)pin_buf, (size_t)pin_w * (size_t)pin_h * 4);
            close(fd);
            if ((dumps_written & 7) == 1)
                spy_log("BRIDGE_V2 wrote %dx%d hwnd=%p bytes=%zu\n",
                        pin_w, pin_h, (void *)login_hwnd, out_bytes);
            wrote_ok = 1;
        }
    }

    if (wrote_ok) {
        if (nonbg > best_unique) best_unique = nonbg;
        dumps_written++;
        dump_write_total++;
        dump_write_sec++;
        live_mode = 1;
        rc = 0;
        /* #region agent log */
        {
            char j[360];
            snprintf(j, sizeof(j),
                     "{\"dump_rc\":0,\"nz\":%u,\"nonbg\":%u,\"bytes\":%zu,\"w\":%d,\"h\":%d,"
                     "\"out\":[%d,%d],\"dstXY\":[%d,%d],\"composite\":%d,\"wrote\":1,\"n\":%d,"
                     "\"hwnd\":\"%p\",\"v2\":1,\"shm\":%d,\"file\":%d}",
                     nz, nonbg, out_bytes, w, h, pin_w, pin_h, xDst, yDst, composite,
                     dumps_written, (void *)login_hwnd, bridge_shm_enabled(),
                     bridge_file_enabled());
            agent_log(composite ? "F" : "C", "fly_stretch_epi_bridge.c:dump_ok",
                      "SRC dump wrote live frame", j);
        }
        /* #endregion */
    } else {
        rc = -6;
        /* #region agent log */
        agent_log("B", "fly_stretch_epi_bridge.c:open_fail", "bridge open failed", "{\"rc\":-6}");
        /* #endregion */
    }
out:
    if (old) p_SelectBitmap(mem, old);
    if (dib && p_DeleteObject) p_DeleteObject(dib);
    if (mem && p_DeleteDC) p_DeleteDC(mem);
    return rc;
}

static long long now_ms_mono(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
}

/* Phase 3b Option B: push login SRC pixels onto the hwnd surface the way Wine's
 * shm present path does (SetDIBitsToDeviceInternal), then flush_window_surfaces.
 * Plain BitBlt→dst returned success but never produced native setColorImage
 * (all 1454×934 paints were login-bridge). SetDIBits is what dirties macdrv DIBs.
 *
 * HARD GATES (Phase 3 cold flush wedged StartView):
 *   - FLY_OPTION_B=1
 *   - live_mode (first successful SRC dump = after Close/hub paint)
 *   - pin_w >= 1400
 *   - ≤10 Hz
 */
static int option_b_enabled(void)
{
    const char *e;
    if (option_b_env < 0) {
        e = getenv("FLY_OPTION_B");
        option_b_env = (e && e[0] == '1') ? 1 : 0;
    }
    return option_b_env;
}

static int option_b_do_flush(void)
{
    const char *e;
    if (option_b_flush_env < 0) {
        e = getenv("FLY_OPTION_B_FLUSH");
        /* Default ON when Option B is on; set FLY_OPTION_B_FLUSH=0 for copy-only. */
        if (!e || !e[0])
            option_b_flush_env = 1;
        else
            option_b_flush_env = (e[0] == '1') ? 1 : 0;
    }
    return option_b_flush_env;
}

static int parent_present_enabled(void)
{
    const char *e;
    if (parent_present_env < 0) {
        e = getenv("FLY_PARENT_PRESENT");
        parent_present_env = (e && e[0] == '1') ? 1 : 0;
    }
    return parent_present_env;
}

/* Parent SetDIBits must run on a Wine TEB thread — Cocoa/GCD hangs GetDCEx.
 * Connect upc.exe and EA EADesktop.exe stop StretchBlt after splash (or never
 * StretchBlt themselves when GPU is a child); hook PeekMessage instead. */
static int is_upc_process(void)
{
    int argc, i;
    char **argv;
    int has_parent = 0, has_start = 0, has_child = 0;
    if (upc_process_cached == 1)
        return 1;
    if (upc_process_cached == 0)
        return 0;
    argc = *_NSGetArgc();
    argv = *_NSGetArgv();
    if (!argv)
        return 0;
    for (i = 0; i < argc; i++) {
        const char *a = argv[i];
        const char *base;
        if (!a) continue;
        if (strcasestr(a, "UplayWebCore") || strcasestr(a, "EACefSubProcess"))
            has_child = 1;
        if (strcasestr(a, "start.exe"))
            has_start = 1;
        base = strrchr(a, '\\');
        if (!base) base = strrchr(a, '/');
        base = base ? base + 1 : a;
        if (strcasecmp(base, "upc.exe") == 0 || strcasecmp(base, "EADesktop.exe") == 0)
            has_parent = 1;
        if (strcasecmp(base, "start.exe") == 0)
            has_start = 1;
    }
    if (has_child || has_start) {
        upc_process_cached = 0;
        return 0;
    }
    if (has_parent) {
        upc_process_cached = 1;
        return 1;
    }
    return 0;
}

static void resolve_parent_gdi(void)
{
    if (!p_GetDCEx)
        p_GetDCEx = (NtUserGetDCEx_fn)dlsym(RTLD_DEFAULT, "NtUserGetDCEx");
    if (!p_GetDCEx)
        p_GetDCEx = (NtUserGetDCEx_fn)dlsym(RTLD_DEFAULT, "_NtUserGetDCEx");
    if (!p_ReleaseDC)
        p_ReleaseDC = (NtUserReleaseDC_fn)dlsym(RTLD_DEFAULT, "NtUserReleaseDC");
    if (!p_ReleaseDC)
        p_ReleaseDC = (NtUserReleaseDC_fn)dlsym(RTLD_DEFAULT, "_NtUserReleaseDC");
    if (!p_SetDIBits)
        p_SetDIBits = (NtGdiSetDIBitsToDeviceInternal_fn)dlsym(RTLD_DEFAULT,
                                                               "NtGdiSetDIBitsToDeviceInternal");
    if (!p_SetDIBits)
        p_SetDIBits = (NtGdiSetDIBitsToDeviceInternal_fn)dlsym(RTLD_DEFAULT,
                                                               "_NtGdiSetDIBitsToDeviceInternal");
    if (!p_CreateCompatibleDC)
        p_CreateCompatibleDC = (NtGdiCreateCompatibleDC_fn)dlsym(RTLD_DEFAULT,
                                                                  "NtGdiCreateCompatibleDC");
    if (!p_CreateDIBSection)
        p_CreateDIBSection = (NtGdiCreateDIBSection_fn)dlsym(RTLD_DEFAULT,
                                                              "NtGdiCreateDIBSection");
    if (!p_SelectBitmap)
        p_SelectBitmap = (NtGdiSelectBitmap_fn)dlsym(RTLD_DEFAULT, "NtGdiSelectBitmap");
    if (!p_BitBlt)
        p_BitBlt = (NtGdiBitBlt_fn)dlsym(RTLD_DEFAULT, "NtGdiBitBlt");
    if (!p_DeleteObject)
        p_DeleteObject = (NtGdiDeleteObjectApp_fn)dlsym(RTLD_DEFAULT, "NtGdiDeleteObjectApp");
    if (!p_DeleteDC)
        p_DeleteDC = (NtGdiDeleteDC_fn)dlsym(RTLD_DEFAULT, "NtGdiDeleteDC");
    resolve_flush_window_surfaces();
}

/* After parent SetDIBits+flush: are non-zero pixels readable back from the hwnd DC?
 * Distinguishes "GDI accepted bits" vs "bits landed on a surface macdrv can flush". */
static void parent_hwnd_sample(HWND hwnd, HDC hdc, int w, int h, int flushed)
{
    HDC smem = 0;
    HBITMAP sdib = 0, sold = 0;
    void *sbits = NULL;
    BITMAPINFO sbmi;
    int sw = w > 64 ? 64 : w;
    int sh = h > 64 ? 64 : h;
    unsigned snz = 0;
    int si;
    int ox, oy;

    if (!hdc || !p_BitBlt || !p_CreateCompatibleDC || !p_CreateDIBSection || !p_SelectBitmap)
        return;
    memset(&sbmi, 0, sizeof(sbmi));
    sbmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    sbmi.bmiHeader.biWidth = sw;
    sbmi.bmiHeader.biHeight = -sh;
    sbmi.bmiHeader.biPlanes = 1;
    sbmi.bmiHeader.biBitCount = 32;
    smem = p_CreateCompatibleDC(hdc);
    if (!smem)
        return;
    sdib = p_CreateDIBSection(smem, NULL, 0, &sbmi, 0, 0, 0, 0, &sbits);
    if (!sdib || !sbits)
        goto done;
    sold = p_SelectBitmap(smem, sdib);
    ox = w / 4;
    oy = h / 4;
    if (p_BitBlt(smem, 0, 0, sw, sh, hdc, ox, oy, 0x00CC0020u, 0, 0)) {
        for (si = 0; si < sw * sh; si++) {
            uint32_t px = ((uint32_t *)sbits)[si];
            if ((px & 0x00ffffffu) != 0)
                snz++;
        }
    }
    spy_log("PARENT_HWND_SAMPLE hwnd=%p nz=%u/%d flush=%d %dx%d @%d,%d\n",
            (void *)hwnd, snz, sw * sh, flushed, w, h, ox, oy);
done:
    if (sold)
        p_SelectBitmap(smem, sold);
    if (sdib && p_DeleteObject)
        p_DeleteObject(sdib);
    if (p_DeleteDC)
        p_DeleteDC(smem);
}

/* ------------------------------------------------------------------ *
 * Fast path (FLY4): faithful blit replay + dirty-rect present.
 *
 * Old path guessed which StretchBlt was "the frame" (pin/near/mid/size
 * gates) and shipped whole 1454x934 frames at 10 Hz — scroll blits fell
 * through the gates and never reached the screen.
 *
 * Here the producer replays EVERY window-targeted blit 1:1 into a shared
 * shadow surface and unions a dirty rect; the parent grabs-and-clears that
 * rect and SetDIBits only those pixels. Same shape as Wine's own
 * window_surface + window_surface_flush.
 * ------------------------------------------------------------------ */
#define BRIDGE_MAGIC_V4 0x34594C46u /* bytes F L Y 4 */
#define BRIDGE_SHM4_NAME "/fly-upc-stretch-bridge4"
#define BRIDGE_SHM4_HDR 64
#define BRIDGE_SHM4_BYTES (BRIDGE_SHM4_HDR + (size_t)BRIDGE_SHM_MAX_W * (size_t)BRIDGE_SHM_MAX_H * 4)

/* Connect keeps the historic name. EA Play sets FLY_BRIDGE_SHM4_NAME so a
 * Steam/Connect FLY4 segment is never shm_unlink'd from the EA bottle. */
static const char *shm4_name(void)
{
    static char buf[128];
    static int once;
    if (!once) {
        const char *e = getenv("FLY_BRIDGE_SHM4_NAME");
        if (e && e[0] == '/' && strlen(e) < sizeof(buf))
            snprintf(buf, sizeof(buf), "%s", e);
        else
            snprintf(buf, sizeof(buf), "%s", BRIDGE_SHM4_NAME);
        once = 1;
    }
    return buf;
}

/* Natural alignment (no packing): `lock` needs 4-byte and hwnd64 8-byte
 * alignment for the atomics. Both sides are built from this header. */
struct fly_shm4 {
    uint32_t magic;             /*  0 */
    int32_t surf_w;             /*  4 */
    int32_t surf_h;             /*  8 */
    volatile uint32_t lock;     /* 12 */
    uint64_t hwnd64;            /* 16 */
    int32_t dx0, dy0, dx1, dy1; /* 24 — accumulated dirty rect; empty when x1<=x0 */
    uint32_t seq;               /* 40 */
    uint32_t gen;               /* 44 */
    uint32_t owner_pid;         /* 48 — producer that owns this session's surface */
    uint32_t pad[3];            /* 52 → 64 */
};

static int fast_env = -1;
static void *shm4_map;
static pthread_mutex_t shm4_mu = PTHREAD_MUTEX_INITIALIZER;
static int shm4_lock_fails;
static pthread_mutex_t fast_mu = PTHREAD_MUTEX_INITIALIZER;
static HDC fast_mem;
static HBITMAP fast_dib, fast_old;
static void *fast_bits;
static int fast_dib_w, fast_dib_h;
static uint32_t *fast_stage;
static size_t fast_stage_bytes;
static long long last_fast_present_ms;
static unsigned fast_blit_sec, fast_present_sec, fast_px_sec;

static int fast_present_enabled(void)
{
    const char *e;
    if (fast_env < 0) {
        e = getenv("FLY_FAST_PRESENT");
        fast_env = (e && e[0] == '1') ? 1 : 0;
    }
    return fast_env;
}

/* The segment is O_CREAT and never unlinked, so on macOS it outlives the session.
 * A run killed mid-frame leaves either a stale dirty rect — the next upc would paint
 * last session's pixels into whatever owns that HWND now — or a `lock` still held by
 * a dead process, which silently drops every blit and present for the whole next run.
 * So the producer claims the surface and reinitialises it when the last owner is gone. */
static void shm4_claim(struct fly_shm4 *sh)
{
    uint32_t prev = sh->owner_pid;
    uint32_t me = (uint32_t)getpid();

    if (prev == me)
        return;
    if (prev && kill((pid_t)prev, 0) == 0)
        return;
    sh->lock = 0;
    sh->hwnd64 = 0;
    sh->dx0 = 0; sh->dy0 = 0; sh->dx1 = 0; sh->dy1 = 0;
    sh->seq = 0;
    sh->gen++;
    sh->owner_pid = me;
    __sync_synchronize();
    spy_log("FAST_CLAIM surface taken from pid=%u (gen=%u)\n", prev, sh->gen);
}

static struct fly_shm4 *shm4_ensure(int create)
{
    int fd;
    void *p;
    if (shm4_map)
        return (struct fly_shm4 *)shm4_map;
    pthread_mutex_lock(&shm4_mu);
    if (shm4_map) {
        pthread_mutex_unlock(&shm4_mu);
        return (struct fly_shm4 *)shm4_map;
    }
    fd = shm_open(shm4_name(), create ? (O_CREAT | O_RDWR) : O_RDWR, 0666);
    if (fd < 0) {
        pthread_mutex_unlock(&shm4_mu);
        return NULL;
    }
    if (create && ftruncate(fd, (off_t)BRIDGE_SHM4_BYTES) != 0) {
        close(fd);
        pthread_mutex_unlock(&shm4_mu);
        return NULL;
    }
    p = mmap(NULL, BRIDGE_SHM4_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) {
        pthread_mutex_unlock(&shm4_mu);
        return NULL;
    }
    if (create)
        shm4_claim((struct fly_shm4 *)p);
    shm4_map = p;
    spy_log("FAST_SHM mapped name=%s create=%d parent=%d\n",
            shm4_name(), create, is_upc_process());
    pthread_mutex_unlock(&shm4_mu);
    return (struct fly_shm4 *)p;
}

/* Both sides hold this only for a rect-sized copy, so spinning is cheap. */
static int shm4_lock(struct fly_shm4 *sh)
{
    int spins = 0;
    while (!__sync_bool_compare_and_swap(&sh->lock, 0u, 1u)) {
        if (++spins > 50000) {
            /* Nothing legitimately holds this longer than a memcpy, so a budget this
             * large means the holder died. Steal it rather than go dark permanently. */
            if (++shm4_lock_fails < 3)
                return 0;
            shm4_lock_fails = 0;
            sh->lock = 1;
            __sync_synchronize();
            spy_log("FAST_LOCK stole lock from dead holder\n");
            return 1;
        }
        sched_yield();
    }
    shm4_lock_fails = 0;
    __sync_synchronize();
    return 1;
}

static void shm4_unlock(struct fly_shm4 *sh)
{
    __sync_synchronize();
    sh->lock = 0;
}

static int fast_ensure_dib(HDC ref, int w, int h)
{
    BITMAPINFO bmi;
    if (fast_mem && fast_bits && fast_dib_w == w && fast_dib_h == h)
        return 1;
    if (fast_mem) {
        if (fast_old)
            p_SelectBitmap(fast_mem, fast_old);
        if (fast_dib && p_DeleteObject)
            p_DeleteObject(fast_dib);
        if (p_DeleteDC)
            p_DeleteDC(fast_mem);
    }
    fast_mem = 0;
    fast_dib = 0;
    fast_old = 0;
    fast_bits = NULL;
    fast_dib_w = 0;
    fast_dib_h = 0;

    memset(&bmi, 0, sizeof(bmi));
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = w;
    bmi.bmiHeader.biHeight = -h;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    fast_mem = p_CreateCompatibleDC(ref);
    if (!fast_mem)
        return 0;
    fast_dib = p_CreateDIBSection(fast_mem, NULL, 0, &bmi, 0, 0, 0, 0, &fast_bits);
    if (!fast_dib || !fast_bits) {
        if (fast_dib && p_DeleteObject)
            p_DeleteObject(fast_dib);
        if (p_DeleteDC)
            p_DeleteDC(fast_mem);
        fast_mem = 0;
        fast_dib = 0;
        fast_bits = NULL;
        return 0;
    }
    fast_old = p_SelectBitmap(fast_mem, fast_dib);
    fast_dib_w = w;
    fast_dib_h = h;
    return 1;
}

/* Distinct geometries only — the same handful repeats thousands of times a second. */
static void fast_log_blit(HWND hwnd, const struct blt_coords *d, const struct blt_coords *s)
{
    static struct { int dx, dy, dw, dh, sx, sy, sw, sh; } seen[64];
    static int nseen;
    int i;

    for (i = 0; i < nseen; i++)
        if (seen[i].dx == d->log_x && seen[i].dy == d->log_y && seen[i].dw == d->log_width &&
            seen[i].dh == d->log_height && seen[i].sx == s->log_x && seen[i].sy == s->log_y &&
            seen[i].sw == s->log_width && seen[i].sh == s->log_height)
            return;
    if (nseen >= (int)(sizeof(seen) / sizeof(seen[0])))
        return;
    seen[nseen].dx = d->log_x; seen[nseen].dy = d->log_y;
    seen[nseen].dw = d->log_width; seen[nseen].dh = d->log_height;
    seen[nseen].sx = s->log_x; seen[nseen].sy = s->log_y;
    seen[nseen].sw = s->log_width; seen[nseen].sh = s->log_height;
    nseen++;
    spy_log("FAST_BLIT #%d hwnd=%p dst=%d,%d %dx%d src=%d,%d %dx%d "
            "dstdev=%d,%d %dx%d dstvis=(%d,%d)-(%d,%d) srcdev=%d,%d %dx%d\n",
            nseen, (void *)hwnd, d->log_x, d->log_y, d->log_width, d->log_height,
            s->log_x, s->log_y, s->log_width, s->log_height,
            d->x, d->y, d->width, d->height,
            d->visrect.left, d->visrect.top, d->visrect.right, d->visrect.bottom,
            s->x, s->y, s->width, s->height);
}

/* Producer (gpu process): replay one blit into the shared shadow surface.
 *
 * xSrc,ySrc matter: CEF's source is its whole-window backing bitmap and a partial
 * present names a sub-rect of it. Reading from 0,0 instead pasted the UI's top-left
 * corner at the destination offset — that was the "nested Connect" doubling, and
 * dropping those blits to hide it is what starved the scroll (HANDOFF §2.22). */
static void fast_replay_blit(HDC hdcDst, HDC hdcSrc, const struct blt_coords *dcoord,
                             const struct blt_coords *scoord)
{
    int xDst = dcoord->log_x, yDst = dcoord->log_y;
    int wDst = dcoord->log_width, hDst = dcoord->log_height;
    int xSrc = scoord->log_x, ySrc = scoord->log_y;
    int wSrc = scoord->log_width, hSrc = scoord->log_height;
    HWND hwnd;
    struct fly_shm4 *sh;
    uint32_t *shadow;
    int need_w, need_h, x, y;

    if (wSrc < 8 || hSrc < 8 || wDst < 8 || hDst < 8)
        return;
    if (wSrc > 4096 || hSrc > 4096 || wDst > 4096 || hDst > 4096)
        return;
    if (!p_WindowFromDC || !p_CreateCompatibleDC || !p_CreateDIBSection || !p_SelectBitmap ||
        !p_BitBlt)
        return;
    /* Only real window DCs. Compositor scratch goes to MEMDCs — replaying those
     * is what produced stacked/nested chrome in the old composite attempts. */
    hwnd = p_WindowFromDC(hdcDst);
    if (!hwnd)
        return;
    login_hwnd = hwnd;

    sh = shm4_ensure(1);
    if (!sh)
        return;

    pthread_mutex_lock(&fast_mu);
    fast_log_blit(hwnd, dcoord, scoord);
    if (!fast_ensure_dib(hdcSrc, wSrc, hSrc))
        goto unlock_mu;
    if (!p_BitBlt(fast_mem, 0, 0, wSrc, hSrc, hdcSrc, xSrc, ySrc, 0x00CC0020u, 0, 0))
        goto unlock_mu;

    need_w = xDst + wDst;
    need_h = yDst + hDst;
    if (need_w > BRIDGE_SHM_MAX_W) need_w = BRIDGE_SHM_MAX_W;
    if (need_h > BRIDGE_SHM_MAX_H) need_h = BRIDGE_SHM_MAX_H;

    if (!shm4_lock(sh))
        goto unlock_mu;

    if (sh->magic != BRIDGE_MAGIC_V4 || sh->surf_w < need_w || sh->surf_h < need_h) {
        int nw = (sh->magic == BRIDGE_MAGIC_V4 && sh->surf_w > need_w) ? sh->surf_w : need_w;
        int nh = (sh->magic == BRIDGE_MAGIC_V4 && sh->surf_h > need_h) ? sh->surf_h : need_h;
        sh->magic = BRIDGE_MAGIC_V4;
        sh->surf_w = nw;
        sh->surf_h = nh;
        sh->gen++;
        sh->dx0 = 0; sh->dy0 = 0; sh->dx1 = nw; sh->dy1 = nh;
    }
    sh->hwnd64 = (uint64_t)(uintptr_t)hwnd;
    shadow = (uint32_t *)((uint8_t *)sh + BRIDGE_SHM4_HDR);

    for (y = 0; y < hDst; y++) {
        int py = yDst + y;
        int sy;
        if (py < 0 || py >= sh->surf_h)
            continue;
        sy = (hDst == hSrc) ? y : (int)((long)y * hSrc / hDst);
        if (sy >= hSrc) sy = hSrc - 1;
        if (wDst == wSrc) {
            int px0 = xDst < 0 ? 0 : xDst;
            int sx0 = px0 - xDst;
            int cw = wDst - sx0;
            if (px0 + cw > sh->surf_w) cw = sh->surf_w - px0;
            if (cw > 0)
                memcpy(&shadow[(size_t)py * sh->surf_w + px0],
                       &((uint32_t *)fast_bits)[(size_t)sy * wSrc + sx0], (size_t)cw * 4);
        } else {
            for (x = 0; x < wDst; x++) {
                int px = xDst + x;
                int sx;
                if (px < 0 || px >= sh->surf_w)
                    continue;
                sx = (int)((long)x * wSrc / wDst);
                if (sx >= wSrc) sx = wSrc - 1;
                shadow[(size_t)py * sh->surf_w + px] =
                    ((uint32_t *)fast_bits)[(size_t)sy * wSrc + sx];
            }
        }
    }

    {
        int x0 = xDst < 0 ? 0 : xDst;
        int y0 = yDst < 0 ? 0 : yDst;
        int x1 = xDst + wDst;
        int y1 = yDst + hDst;
        if (x1 > sh->surf_w) x1 = sh->surf_w;
        if (y1 > sh->surf_h) y1 = sh->surf_h;
        if (x1 > x0 && y1 > y0) {
            if (sh->dx1 <= sh->dx0 || sh->dy1 <= sh->dy0) {
                sh->dx0 = x0; sh->dy0 = y0; sh->dx1 = x1; sh->dy1 = y1;
            } else {
                if (x0 < sh->dx0) sh->dx0 = x0;
                if (y0 < sh->dy0) sh->dy0 = y0;
                if (x1 > sh->dx1) sh->dx1 = x1;
                if (y1 > sh->dy1) sh->dy1 = y1;
            }
        }
    }
    sh->seq++;
    shm4_unlock(sh);
    fast_blit_sec++;

unlock_mu:
    pthread_mutex_unlock(&fast_mu);
}

/* Consumer (upc): present the accumulated dirty rect only. */
static void fast_parent_present(void)
{
    struct fly_shm4 *sh;
    uint32_t *shadow;
    int x0, y0, x1, y1, rw, rh, y;
    HWND hwnd;
    HDC hdc;
    BITMAPINFO bmi;
    INT rc;
    long long now = now_ms_mono();

    if (last_fast_present_ms && now - last_fast_present_ms < 8)
        return;

    sh = shm4_ensure(0);
    if (!sh || sh->magic != BRIDGE_MAGIC_V4 || !sh->hwnd64)
        return;
    if (sh->dx1 <= sh->dx0 || sh->dy1 <= sh->dy0) /* nothing new — cheap check */
        return;
    /* Left over from a previous run: painting it would stamp last session's pixels
     * into whichever window inherited that HWND (0x200aa recurs across runs). */
    if (!sh->owner_pid || kill((pid_t)sh->owner_pid, 0) != 0) {
        sh->dx0 = 0; sh->dy0 = 0; sh->dx1 = 0; sh->dy1 = 0;
        sh->hwnd64 = 0;
        return;
    }

    resolve_parent_gdi();
    if (!p_GetDCEx || !p_SetDIBits || !p_ReleaseDC)
        return;

    if (!shm4_lock(sh))
        return;
    x0 = sh->dx0; y0 = sh->dy0; x1 = sh->dx1; y1 = sh->dy1;
    if (x1 <= x0 || y1 <= y0) {
        shm4_unlock(sh);
        return;
    }
    rw = x1 - x0;
    rh = y1 - y0;
    if ((size_t)rw * rh * 4 > fast_stage_bytes) {
        void *nb = realloc(fast_stage, (size_t)rw * rh * 4);
        if (!nb) {
            shm4_unlock(sh);
            return;
        }
        fast_stage = (uint32_t *)nb;
        fast_stage_bytes = (size_t)rw * rh * 4;
    }
    shadow = (uint32_t *)((uint8_t *)sh + BRIDGE_SHM4_HDR);
    for (y = 0; y < rh; y++)
        memcpy(&fast_stage[(size_t)y * rw],
               &shadow[(size_t)(y0 + y) * sh->surf_w + x0], (size_t)rw * 4);
    sh->dx0 = 0; sh->dy0 = 0; sh->dx1 = 0; sh->dy1 = 0;
    hwnd = (HWND)(uintptr_t)sh->hwnd64;
    shm4_unlock(sh);

    last_fast_present_ms = now;

    hdc = p_GetDCEx(hwnd, 0, DCX_CLIPSIBLINGS);
    if (!hdc) {
        parent_present_fail++;
        return;
    }
    memset(&bmi, 0, sizeof(bmi));
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = rw;
    bmi.bmiHeader.biHeight = -rh;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    rc = p_SetDIBits(hdc, x0, y0, (DWORD)rw, (DWORD)rh, 0, 0, 0, (UINT)rh, fast_stage, &bmi,
                     DIB_RGB_COLORS, 0, 0, 0, 0);
    if (p_flush_window_surfaces)
        p_flush_window_surfaces(1);
    p_ReleaseDC(hwnd, hdc);
    if (rc > 0) {
        parent_present_ok++;
        fast_present_sec++;
        fast_px_sec += (unsigned)(rw * rh);
    } else {
        parent_present_fail++;
    }
}

/* Called from NtUserPeekMessage trampoline on upc Wine UI thread. */
__attribute__((noinline)) static void fly_peek_parent_poll(void)
{
    static __thread int in_parent;
    struct stat st;
    long mtime_ns;
    long long now;
    int fd;
    uint8_t hdr[20];
    uint32_t magic = 0;
    int w = 0, h = 0;
    uint64_t hwnd64 = 0;
    size_t nbytes;
    void *bits = NULL;
    HWND hwnd;
    HDC hdc;
    BITMAPINFO bmi;
    INT dib_rc;
    int flushed = 0;
    ssize_t rd;
    int from_shm = 0;

    if (in_parent || !parent_present_enabled() || !is_upc_process())
        return;
    in_parent = 1;

    if (fast_present_enabled()) {
        fast_parent_present();
        in_parent = 0;
        return;
    }

    now = now_ms_mono();
    /* Rate-limit before I/O — PeekMessage is extremely hot. */
    if (last_parent_present_ms && now - last_parent_present_ms < 100)
        goto out;
    last_parent_present_ms = now;

    resolve_parent_gdi();
    if (!p_GetDCEx || !p_SetDIBits || !p_ReleaseDC)
        goto out;

    /* Prefer shm (seq-based); fall back to v2 file. */
    if (bridge_shm_read_new(&last_parent_shm_seq, &w, &h, &hwnd64, &bits)) {
        from_shm = 1;
    } else {
        if (stat(bridge_path(), &st) != 0)
            goto out;
        mtime_ns = (long)st.st_mtimespec.tv_sec * 1000000000L + (long)st.st_mtimespec.tv_nsec;
        if (mtime_ns == last_parent_mtime_ns)
            goto out;
        fd = open(bridge_path(), O_RDONLY);
        if (fd < 0)
            goto out;
        rd = read(fd, hdr, 20);
        if (rd != 20) {
            close(fd);
            goto out;
        }
        memcpy(&magic, hdr, 4);
        memcpy(&w, hdr + 4, 4);
        memcpy(&h, hdr + 8, 4);
        memcpy(&hwnd64, hdr + 12, 8);
        if (magic != BRIDGE_MAGIC_V2 || w < 8 || h < 8 || w > 4096 || h > 4096 || !hwnd64) {
            close(fd);
            goto out;
        }
        nbytes = (size_t)w * (size_t)h * 4;
        bits = malloc(nbytes);
        if (!bits) {
            close(fd);
            goto out;
        }
        rd = read(fd, bits, nbytes);
        close(fd);
        if (rd != (ssize_t)nbytes) {
            free(bits);
            bits = NULL;
            goto out;
        }
        last_parent_mtime_ns = mtime_ns;
    }

    hwnd = (HWND)(uintptr_t)hwnd64;
    hdc = p_GetDCEx(hwnd, 0, DCX_CLIPSIBLINGS);
    if (!hdc) {
        parent_present_fail++;
        spy_log("PARENT_PRESENT GetDCEx fail hwnd=%p\n", (void *)hwnd);
        free(bits);
        bits = NULL;
        goto out;
    }
    memset(&bmi, 0, sizeof(bmi));
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = w;
    bmi.bmiHeader.biHeight = -h;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = 0;
    dib_rc = p_SetDIBits(hdc, 0, 0, (DWORD)w, (DWORD)h, 0, 0, 0, (UINT)h, bits, &bmi,
                         DIB_RGB_COLORS, 0, 0, 0, 0);
    if (p_flush_window_surfaces) {
        p_flush_window_surfaces(1);
        flushed = 1;
    }
    /* Sample before ReleaseDC — same DC we just painted. */
    if (dib_rc > 0 && (parent_present_ok % 3u) == 0u)
        parent_hwnd_sample(hwnd, hdc, w, h, flushed);
    p_ReleaseDC(hwnd, hdc);
    free(bits);
    bits = NULL;
    if (dib_rc > 0) {
        parent_present_ok++;
        spy_log("PARENT_PRESENT ok hwnd=%p dib=%d flush=%d %dx%d flush_fn=%p shm=%d ok=%u fail=%u\n",
                (void *)hwnd, dib_rc, flushed, w, h, (void *)p_flush_window_surfaces,
                from_shm, parent_present_ok, parent_present_fail);
        /* #region agent log */
        {
            static long long last_emit_ms;
            long long dt = last_emit_ms ? (now - last_emit_ms) : -1;
            char j[224];
            snprintf(j, sizeof(j),
                     "{\"interval_ms\":%lld,\"from_shm\":%d,\"wh\":[%d,%d],"
                     "\"ok\":%u,\"fail\":%u,\"shm_seq\":%u}",
                     dt, from_shm, w, h, parent_present_ok, parent_present_fail,
                     last_parent_shm_seq);
            dbg_log("H3", "fly_stretch_epi_bridge.c:parent_present",
                    "consumer present cadence (interval since last present)", j);
            last_emit_ms = now;
        }
        /* #endregion */
    } else {
        parent_present_fail++;
        spy_log("PARENT_PRESENT SetDIBits fail hwnd=%p dib=%d %dx%d\n",
                (void *)hwnd, dib_rc, w, h);
    }
out:
    if (bits)
        free(bits);
    in_parent = 0;
}

static void resolve_flush_window_surfaces(void)
{
    uint8_t *wsf;
    if (p_flush_window_surfaces)
        return;
    wsf = (uint8_t *)dlsym(RTLD_DEFAULT, "window_surface_flush");
    if (!wsf)
        wsf = (uint8_t *)dlsym(RTLD_DEFAULT, "_window_surface_flush");
    if (!wsf)
        return;
    /* frankea win32u: window_surface_flush @ 0x14e50, flush_window_surfaces @ 0x175e0 */
    p_flush_window_surfaces = (flush_window_surfaces_fn)(wsf - 0x14e50 + 0x175e0);
}

static void try_option_b(HDC hdcDst, HDC hdcSrc, int xDst, int yDst, int w, int h)
{
    long long now;
    BOOL blit_ok = 0;
    INT dib_rc = -1;
    int flushed = 0;
    int used_getdc = 0;
    HDC win_dc = 0;
    HDC mem = 0;
    HBITMAP dib = 0, old = 0;
    void *bits = NULL;
    BITMAPINFO bmi;
    HDC target;

    if (!option_b_enabled())
        return;
    if (!live_mode || pin_w < 1400 || pin_h < 650)
        return;
    if (!hdcSrc || w < 8 || h < 8 || w > 4096 || h > 4096)
        return;

    now = now_ms_mono();
    if (last_option_b_ms && now - last_option_b_ms < 100)
        return;
    last_option_b_ms = now;

    /* Prefer GetDCEx(login_hwnd) — same pattern as process_surface_message. */
    if (login_hwnd && p_GetDCEx) {
        win_dc = p_GetDCEx(login_hwnd, 0, DCX_CLIPSIBLINGS);
        if (win_dc)
            used_getdc = 1;
    }
    if (!win_dc && login_hwnd && p_GetDC) {
        win_dc = p_GetDC(login_hwnd);
        if (win_dc)
            used_getdc = 1;
    }
    target = win_dc ? win_dc : hdcDst;
    if (!target)
        goto done_count;

    /* Capture SRC into a top-down 32bpp DIB, then SetDIBitsToDevice onto hwnd. */
    if (p_SetDIBits && p_CreateCompatibleDC && p_CreateDIBSection && p_SelectBitmap && p_BitBlt) {
        memset(&bmi, 0, sizeof(bmi));
        bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
        bmi.bmiHeader.biWidth = w;
        bmi.bmiHeader.biHeight = -h;
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;
        bmi.bmiHeader.biCompression = 0;
        mem = p_CreateCompatibleDC(hdcSrc);
        if (mem) {
            dib = p_CreateDIBSection(mem, NULL, 0, &bmi, 0, 0, 0, 0, &bits);
            if (dib && bits) {
                old = p_SelectBitmap(mem, dib);
                if (p_BitBlt(mem, 0, 0, w, h, hdcSrc, 0, 0, 0x00CC0020u, 0, 0)) {
                    dib_rc = p_SetDIBits(target, xDst, yDst, (DWORD)w, (DWORD)h,
                                         0, 0, 0, (UINT)h, bits, &bmi, DIB_RGB_COLORS,
                                         0, 0, 0, 0);
                    if (dib_rc > 0)
                        option_b_dib_ok++;
                }
                if (old)
                    p_SelectBitmap(mem, old);
            }
            if (dib && p_DeleteObject)
                p_DeleteObject(dib);
            if (p_DeleteDC)
                p_DeleteDC(mem);
        }
    }

    /* Fallback: plain SRCCOPY BitBlt (proven to return success but not paint). */
    if (dib_rc <= 0 && p_BitBlt) {
        blit_ok = p_BitBlt(target, xDst, yDst, w, h, hdcSrc, 0, 0, 0x00CC0020u, 0, 0);
        if (blit_ok)
            option_b_blit_ok++;
    }

    if (option_b_do_flush()) {
        resolve_flush_window_surfaces();
        if (p_flush_window_surfaces) {
            p_flush_window_surfaces(1);
            flushed = 1;
            option_b_flush_ok++;
        }
    }

    /* Sample hwnd DC after SetDIBits+flush — are pixels actually on the window? */
    if (login_hwnd && p_BitBlt && p_CreateCompatibleDC && p_CreateDIBSection &&
        (dib_rc > 0 || blit_ok) && (option_b_total % 3u) == 0u) {
        HDC sample_dc = used_getdc && win_dc ? win_dc : 0;
        int release_sample = 0;
        HDC smem = 0;
        HBITMAP sdib = 0, sold = 0;
        void *sbits = NULL;
        BITMAPINFO sbmi;
        int sw = w > 64 ? 64 : w;
        int sh = h > 64 ? 64 : h;
        unsigned snz = 0;
        int si;
        if (!sample_dc && p_GetDCEx) {
            sample_dc = p_GetDCEx(login_hwnd, 0, DCX_CLIPSIBLINGS);
            release_sample = sample_dc ? 1 : 0;
        }
        if (sample_dc) {
            memset(&sbmi, 0, sizeof(sbmi));
            sbmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
            sbmi.bmiHeader.biWidth = sw;
            sbmi.bmiHeader.biHeight = -sh;
            sbmi.bmiHeader.biPlanes = 1;
            sbmi.bmiHeader.biBitCount = 32;
            smem = p_CreateCompatibleDC(sample_dc);
            if (smem) {
                sdib = p_CreateDIBSection(smem, NULL, 0, &sbmi, 0, 0, 0, 0, &sbits);
                if (sdib && sbits) {
                    sold = p_SelectBitmap(smem, sdib);
                    if (p_BitBlt(smem, 0, 0, sw, sh, sample_dc, xDst + w / 4, yDst + h / 4,
                                 0x00CC0020u, 0, 0)) {
                        for (si = 0; si < sw * sh; si++) {
                            if (((uint32_t *)sbits)[si] & 0x00FFFFFFu)
                                snz++;
                        }
                    }
                    if (sold)
                        p_SelectBitmap(smem, sold);
                }
                if (sdib && p_DeleteObject)
                    p_DeleteObject(sdib);
                if (p_DeleteDC)
                    p_DeleteDC(smem);
            }
            spy_log("HWND_SAMPLE hwnd=%p nz=%u/%d dib_rc=%d flush=%d surface_probe=1\n",
                    (void *)login_hwnd, snz, sw * sh, dib_rc, flushed);
            if (release_sample && p_ReleaseDC)
                p_ReleaseDC(login_hwnd, sample_dc);
        }
    }

    if (used_getdc && win_dc && p_ReleaseDC)
        p_ReleaseDC(login_hwnd, win_dc);

done_count:
    option_b_total++;
    option_b_sec++;

    spy_log("OPTION_B #%u dib=%d blit=%d flush=%d getdc=%d %dx%d @%d,%d hwnd=%p pin=%dx%d\n",
            option_b_total, dib_rc, blit_ok ? 1 : 0, flushed, used_getdc, w, h, xDst, yDst,
            (void *)login_hwnd, pin_w, pin_h);
}

static void rate_tick(long long now_ms)
{
    char buf[256];
    if (rate_bucket_ms == 0) rate_bucket_ms = now_ms;
    if (now_ms - rate_bucket_ms < 1000) return;
    /* #region agent log */
    snprintf(buf, sizeof(buf),
             "{\"epi_sec\":%u,\"write_sec\":%u,\"composite_sec\":%u,\"size_skip_sec\":%u,"
             "\"nest_skip_sec\":%u,\"gate_skip_sec\":%u,\"throttle_skip_sec\":%u,"
             "\"ident_skip_sec\":%u,\"epi_total\":%u,\"write_total\":%u,"
             "\"size_skip_total\":%u,\"nest_skip_total\":%u,\"ident_skip\":%u,"
             "\"pin\":[%d,%d],\"hwnd\":\"%p\"}",
             epi_login_sec, dump_write_sec, composite_sec, size_skip_sec, nest_skip_sec,
             gate_skip_sec, throttle_skip_sec, ident_skip_sec, epi_login_total,
             dump_write_total, size_skip_total, nest_skip_total, identical_skip_total,
             pin_w, pin_h, (void *)login_hwnd);
    agent_log("F", "fly_stretch_epi_bridge.c:rate", "present rate 1s", buf);
    spy_log("RATE epi/s=%u write/s=%u comp/s=%u optB/s=%u gate_skip/s=%u thr_skip/s=%u ident/s=%u "
            "size_skip/s=%u nest_skip/s=%u pin=%dx%d hwnd=%p optB_total=%u blit_ok=%u dib_ok=%u flush_ok=%u\n",
            epi_login_sec, dump_write_sec, composite_sec, option_b_sec, gate_skip_sec, throttle_skip_sec,
            ident_skip_sec, size_skip_sec, nest_skip_sec, pin_w, pin_h, (void *)login_hwnd,
            option_b_total, option_b_blit_ok, option_b_dib_ok, option_b_flush_ok);
    /* #endregion */
    /* #region agent log */
    {
        char j[400];
        snprintf(j, sizeof(j),
                 "{\"epi_win_sec\":%u,\"write_sec\":%u,\"comp_sec\":%u,\"size_skip_sec\":%u,"
                 "\"gate_skip_sec\":%u,\"throttle_skip_sec\":%u,\"ident_skip_sec\":%u,"
                 "\"any_sub_sec\":%u,\"optB_sec\":%u,\"pin\":[%d,%d],"
                 "\"fast_blit_sec\":%u,\"fast_present_sec\":%u,\"fast_kpx_sec\":%u}",
                 epi_login_sec, dump_write_sec, composite_sec, size_skip_sec, gate_skip_sec,
                 throttle_skip_sec, ident_skip_sec, any_sub_sec, option_b_sec, pin_w, pin_h,
                 fast_blit_sec, fast_present_sec, fast_px_sec / 1000u);
        dbg_log("H1", "fly_stretch_epi_bridge.c:rate",
                "producer 1s counters (writes vs drops)", j);
    }
    /* #endregion */
    if (fast_present_enabled())
        spy_log("FAST blit/s=%u present/s=%u kpx/s=%u hwnd=%p\n",
                fast_blit_sec, fast_present_sec, fast_px_sec / 1000u, (void *)login_hwnd);
    epi_login_sec = 0;
    dump_write_sec = 0;
    composite_sec = 0;
    option_b_sec = 0;
    size_skip_sec = 0;
    nest_skip_sec = 0;
    gate_skip_sec = 0;
    throttle_skip_sec = 0;
    ident_skip_sec = 0;
    any_sub_sec = 0;
    fast_blit_sec = 0;
    fast_present_sec = 0;
    fast_px_sec = 0;
    rate_bucket_ms = now_ms;
}

__attribute__((noinline)) static void fly_after_stretch(void)
{
    static __thread int in_cb;
    void *stretch_rbp;
    const struct blt_coords *dcoord, *scoord;
    int xDst, yDst, widthDst, heightDst, widthSrc, heightSrc;
    HDC hdcSrc, hdcDst;
    char buf[512];
    unsigned nz = 0;
    int dump_rc = 0;
    long long now_ms;

    if (in_cb) return;
    in_cb = 1;

    __asm__ volatile("movq (%%rbp), %0" : "=r"(stretch_rbp));

    hdcDst = *(HDC *)((char *)stretch_rbp - FRAME_HDC_DST);
    hdcSrc = *(HDC *)((char *)stretch_rbp - FRAME_HDC_SRC);
    dcoord = (const struct blt_coords *)((char *)stretch_rbp - FRAME_DST_COORDS);
    scoord = (const struct blt_coords *)((char *)stretch_rbp - FRAME_SRC_COORDS);
    xDst = dcoord->log_x;
    yDst = dcoord->log_y;
    widthDst = dcoord->log_width;
    heightDst = dcoord->log_height;
    widthSrc = scoord->log_width;
    heightSrc = scoord->log_height;
    now_ms = now_ms_mono();

    if (fast_present_enabled()) {
        fast_replay_blit(hdcDst, hdcSrc, dcoord, scoord);
        rate_tick(now_ms);
        in_cb = 0;
        return;
    }

    /* Log first small blits + ongoing medium/large (hub after login != 1454 only). */
    if (any_logs < 8 || widthSrc >= 400 || widthDst >= 400) {
        if (any_logs < 32 || widthSrc >= 400) {
            if (any_logs < 32) any_logs++;
            if (widthSrc >= 400 || any_logs <= 8) {
                spy_log("ANY_EPI #%d dst=%p src=%p dstWH=%dx%d srcWH=%dx%d\n",
                        any_logs, (void *)hdcDst, (void *)hdcSrc,
                        widthDst, heightDst, widthSrc, heightSrc);
            }
        }
    }

    /* Bridge window-sized presents (login 1454×934 and post-login hub). */
    if ((widthDst >= 600 && heightDst >= 400) || (widthSrc >= 600 && heightSrc >= 400)) {
        epi_login_total++;
        epi_login_sec++;
        if (p_WindowFromDC && hdcDst) {
            HWND hwnd = p_WindowFromDC(hdcDst);
            if (hwnd) login_hwnd = hwnd;
        }
        if (login_logs < 128) {
            login_logs++;
            spy_log("LOGIN_EPI #%d dst=%p src=%p hwnd=%p dstWH=%dx%d srcWH=%dx%d\n",
                    login_logs, (void *)hdcDst, (void *)hdcSrc, (void *)login_hwnd,
                    widthDst, heightDst, widthSrc, heightSrc);
            snprintf(buf, sizeof(buf),
                     "{\"n\":%d,\"dst\":\"%p\",\"src\":\"%p\",\"hwnd\":\"%p\","
                     "\"dstWH\":[%d,%d],\"srcWH\":[%d,%d]}",
                     login_logs, (void *)hdcDst, (void *)hdcSrc, (void *)login_hwnd,
                     widthDst, heightDst, widthSrc, heightSrc);
            agent_log("H", "fly_stretch_epi_bridge.c:after", "window-size StretchBlt epilogue", buf);
        }
        /* Full/near replace pin_buf; mid dirty (1068×291 typing) composites at xDst,yDst.
         * Always write pin-sized .bgra so inject size-match stays correct (§2.21). */
        {
            int login_like = (widthSrc >= 1400 && heightSrc >= 900);
            int pinned = (pin_w > 0 && widthSrc == pin_w && heightSrc == pin_h);
            int near = near_pin_ok(widthSrc, heightSrc);
            int mid_dirty = mid_dirty_ok(widthSrc, heightSrc);
            int mid_rep = mid_replace_ok(widthSrc, heightSrc);
            int thr_ms = (mid_dirty || mid_rep) ? 33 : 50;
            if (getenv("FLY_STRETCH_DUMP")) {
                if (!(login_like || pinned || near || mid_dirty || mid_rep)) {
                    gate_skip_sec++;
                    /* #region agent log */
                    if ((gate_skip_sec & 31u) == 1u) {
                        snprintf(buf, sizeof(buf),
                                 "{\"wh\":[%d,%d],\"dstXY\":[%d,%d],\"pin\":[%d,%d],"
                                 "\"gate_skip_sec\":%u}",
                                 widthSrc, heightSrc, xDst, yDst, pin_w, pin_h, gate_skip_sec);
                        agent_log("G", "fly_stretch_epi_bridge.c:gate_skip",
                                  "SRC dump gated", buf);
                        dbg_log("H1", "fly_stretch_epi_bridge.c:gate_skip",
                                "window-size present gated (scroll frame dropped?)", buf);
                    }
                    /* #endregion */
                } else if (live_mode && now_ms - last_live_ms < thr_ms) {
                    throttle_skip_sec++;
                } else {
                    unsigned nonbg = 0;
                    /* Only small dirty strips composite; large mid_rep is gated off. */
                    int composite = mid_dirty && !(login_like || pinned || near);
                    dump_rc = dump_src_bgra(hdcSrc, widthSrc, heightSrc, xDst, yDst,
                                            widthDst, heightDst, composite, &nz, &nonbg);
                    dumps_done++;
                    last_live_ms = now_ms;
                    spy_log("SRC_DUMP rc=%d nz=%u nonbg=%u written=%d live=%d %dx%d "
                            "dst=%d,%d pin=%dx%d near=%d dirty=%d rep=%d comp=%d\n",
                            dump_rc, nz, nonbg, dumps_written, live_mode,
                            widthSrc, heightSrc, xDst, yDst, pin_w, pin_h, near,
                            mid_dirty, mid_rep, composite);
                    snprintf(buf, sizeof(buf),
                             "{\"dump_rc\":%d,\"nz\":%u,\"nonbg\":%u,\"written\":%d,"
                             "\"wh\":[%d,%d],\"dstXY\":[%d,%d],\"pin\":[%d,%d],"
                             "\"near\":%d,\"dirty\":%d,\"rep\":%d,\"composite\":%d}",
                             dump_rc, nz, nonbg, dumps_written, widthSrc, heightSrc,
                             xDst, yDst, pin_w, pin_h, near, mid_dirty, mid_rep, composite);
                    agent_log("G", "fly_stretch_epi_bridge.c:dump", "SRC dump attempt", buf);
                    /* Option B: full/near login frames only (not mid dirty composite). */
                    if (live_mode && nonbg >= 5000u && !composite)
                        try_option_b(hdcDst, hdcSrc, xDst, yDst, widthSrc, heightSrc);
                }
            }
        }
    } else {
        any_sub_sec++;
    }
    rate_tick(now_ms);
    in_cb = 0;
}

static int install_epi_hook(void)
{
    uint8_t *fn;
    uint8_t *cave;
    int off = 0;
    int rc = 0;

    /* Constructor + dyld add_image + late thread raced: same process logged
     * two "epi hooked" lines to different caves (spy pid=20123) → corrupt trampoline. */
    pthread_mutex_lock(&install_mu);
    if (hooked) {
        pthread_mutex_unlock(&install_mu);
        return 1;
    }
    fn = (uint8_t *)dlsym(RTLD_DEFAULT, "NtGdiStretchBlt");
    if (!fn) fn = (uint8_t *)dlsym(RTLD_DEFAULT, "_NtGdiStretchBlt");
    if (!fn) {
        pthread_mutex_unlock(&install_mu);
        return 0;
    }

    epi_addr = fn + EPI_OFF_FROM_STRETCH;
    if (memcmp(epi_addr, EPI_ORIG, EPI_LEN) != 0) {
        if (epi_addr[0] == 0xE9 || (epi_addr[0] == 0x48 && epi_addr[1] == 0xb8)) {
            /* Already patched (or in-progress absolute jmp) — treat as done. */
            hooked = 1;
            spy_log("epi already patched @ %p — skip second install\n", (void *)epi_addr);
            agent_log("H", "fly_stretch_epi_bridge.c:install", "epi already patched", "{\"skip\":1}");
            pthread_mutex_unlock(&install_mu);
            return 1;
        }
        spy_log("UNEXPECTED epi bytes @ %p: %02x%02x%02x%02x\n",
                (void *)epi_addr, epi_addr[0], epi_addr[1], epi_addr[2], epi_addr[3]);
        agent_log("H", "fly_stretch_epi_bridge.c:install", "unexpected epi", "{\"ok\":0}");
        pthread_mutex_unlock(&install_mu);
        return 0;
    }

    p_CreateCompatibleDC = (NtGdiCreateCompatibleDC_fn)dlsym(RTLD_DEFAULT, "NtGdiCreateCompatibleDC");
    p_CreateDIBSection = (NtGdiCreateDIBSection_fn)dlsym(RTLD_DEFAULT, "NtGdiCreateDIBSection");
    p_SelectBitmap = (NtGdiSelectBitmap_fn)dlsym(RTLD_DEFAULT, "NtGdiSelectBitmap");
    p_BitBlt = (NtGdiBitBlt_fn)dlsym(RTLD_DEFAULT, "NtGdiBitBlt");
    p_DeleteObject = (NtGdiDeleteObjectApp_fn)dlsym(RTLD_DEFAULT, "NtGdiDeleteObjectApp");
    p_DeleteDC = (NtGdiDeleteDC_fn)dlsym(RTLD_DEFAULT, "NtGdiDeleteDC");
    p_WindowFromDC = (NtUserWindowFromDC_fn)dlsym(RTLD_DEFAULT, "NtUserWindowFromDC");
    p_GetDC = (NtUserGetDC_fn)dlsym(RTLD_DEFAULT, "NtUserGetDC");
    if (!p_GetDC) p_GetDC = (NtUserGetDC_fn)dlsym(RTLD_DEFAULT, "_NtUserGetDC");
    p_GetDCEx = (NtUserGetDCEx_fn)dlsym(RTLD_DEFAULT, "NtUserGetDCEx");
    if (!p_GetDCEx) p_GetDCEx = (NtUserGetDCEx_fn)dlsym(RTLD_DEFAULT, "_NtUserGetDCEx");
    p_ReleaseDC = (NtUserReleaseDC_fn)dlsym(RTLD_DEFAULT, "NtUserReleaseDC");
    if (!p_ReleaseDC) p_ReleaseDC = (NtUserReleaseDC_fn)dlsym(RTLD_DEFAULT, "_NtUserReleaseDC");
    p_SetDIBits = (NtGdiSetDIBitsToDeviceInternal_fn)dlsym(RTLD_DEFAULT, "NtGdiSetDIBitsToDeviceInternal");
    if (!p_SetDIBits)
        p_SetDIBits = (NtGdiSetDIBitsToDeviceInternal_fn)dlsym(RTLD_DEFAULT, "_NtGdiSetDIBitsToDeviceInternal");
    if (option_b_enabled())
        resolve_flush_window_surfaces();
    /* #region agent log */
    {
        char j[520];
        snprintf(j, sizeof(j),
                 "{\"cdc\":%d,\"dib\":%d,\"sel\":%d,\"blt\":%d,\"delObj\":%d,\"delDC\":%d,"
                 "\"wfdc\":%d,\"getdc\":%d,\"getdcex\":%d,\"reldc\":%d,\"setdib\":%d,"
                 "\"flush\":%d,\"dumpEnv\":%d,\"optB\":%d}",
                 p_CreateCompatibleDC ? 1 : 0, p_CreateDIBSection ? 1 : 0, p_SelectBitmap ? 1 : 0,
                 p_BitBlt ? 1 : 0, p_DeleteObject ? 1 : 0, p_DeleteDC ? 1 : 0,
                 p_WindowFromDC ? 1 : 0, p_GetDC ? 1 : 0, p_GetDCEx ? 1 : 0, p_ReleaseDC ? 1 : 0,
                 p_SetDIBits ? 1 : 0, p_flush_window_surfaces ? 1 : 0,
                 getenv("FLY_STRETCH_DUMP") ? 1 : 0, option_b_enabled());
        agent_log("B", "fly_stretch_epi_bridge.c:gdi_resolve", "GDI symbols for dump", j);
        spy_log("gdi_resolve dump=%d optB=%d flush_fn=%p setdib=%d getdcex=%d\n",
                getenv("FLY_STRETCH_DUMP") ? 1 : 0, option_b_enabled(),
                (void *)p_flush_window_surfaces, p_SetDIBits ? 1 : 0, p_GetDCEx ? 1 : 0);
    }
    /* #endregion */

    cave_page = mmap(NULL, PAGE_SIZE, PROT_READ | PROT_WRITE | PROT_EXEC,
                     MAP_ANON | MAP_PRIVATE, -1, 0);
    if (cave_page == MAP_FAILED) {
        cave_page = NULL;
        pthread_mutex_unlock(&install_mu);
        return 0;
    }
    cave = cave_page;
    memset(cave, 0x90, PAGE_SIZE);

    cave[off++] = 0x50; /* push rax */
    cave[off++] = 0x51;
    cave[off++] = 0x52;
    cave[off++] = 0x56;
    cave[off++] = 0x57;
    cave[off++] = 0x41; cave[off++] = 0x50;
    cave[off++] = 0x41; cave[off++] = 0x51;
    cave[off++] = 0x48; cave[off++] = 0xb8;
    {
        void *fp = (void *)fly_after_stretch;
        memcpy(cave + off, &fp, 8);
        off += 8;
    }
    cave[off++] = 0xff; cave[off++] = 0xd0; /* call rax */
    cave[off++] = 0x41; cave[off++] = 0x59;
    cave[off++] = 0x41; cave[off++] = 0x58;
    cave[off++] = 0x5f;
    cave[off++] = 0x5e;
    cave[off++] = 0x5a;
    cave[off++] = 0x59;
    cave[off++] = 0x58;
    memcpy(cave + off, EPI_ORIG, EPI_LEN);

    if (make_rwx(epi_addr, EPI_LEN) != 0) {
        spy_log("mprotect epi failed\n");
        pthread_mutex_unlock(&install_mu);
        return 0;
    }
    emit_jmp(epi_addr, cave);
    memset(epi_addr + 12, 0xCC, EPI_LEN - 12);
    hooked = 1;
    rc = 1;
    spy_log("epi hooked @ %p -> cave %p\n", (void *)epi_addr, (void *)cave);
    agent_log("H", "fly_stretch_epi_bridge.c:install", "epi hook installed", "{\"ok\":1}");
    pthread_mutex_unlock(&install_mu);
    return rc;
}

#define PEEK_STEAL 14

static int install_peek_parent_hook(void)
{
    uint8_t *fn;
    uint8_t *cave;
    int off = 0;
    /* 14 bytes: push rbp; mov rbp,rsp; push r14; push rbx; sub rsp,0x70; mov rdi,rbx
     * Abs trampoline is 12 bytes — must steal a full instruction run ≥12. */

    if (!parent_present_enabled() || !is_upc_process())
        return 0;

    pthread_mutex_lock(&install_mu);
    if (peek_hooked) {
        pthread_mutex_unlock(&install_mu);
        return 1;
    }
    fn = (uint8_t *)dlsym(RTLD_DEFAULT, "NtUserPeekMessage");
    if (!fn)
        fn = (uint8_t *)dlsym(RTLD_DEFAULT, "_NtUserPeekMessage");
    if (!fn) {
        pthread_mutex_unlock(&install_mu);
        return 0;
    }
    if (fn[0] == 0x48 && fn[1] == 0xb8) {
        peek_hooked = 1;
        pthread_mutex_unlock(&install_mu);
        return 1;
    }
    /* Standard prologue + mov rdi,rbx */
    if (fn[0] != 0x55 || fn[1] != 0x48 || fn[2] != 0x89 || fn[3] != 0xe5 ||
        fn[11] != 0x48 || fn[12] != 0x89 || fn[13] != 0xfb) {
        spy_log("UNEXPECTED PeekMessage prologue %02x%02x%02x%02x…%02x%02x%02x — skip parent hook\n",
                fn[0], fn[1], fn[2], fn[3], fn[11], fn[12], fn[13]);
        pthread_mutex_unlock(&install_mu);
        return 0;
    }

    resolve_parent_gdi();
    peek_cave_page = mmap(NULL, PAGE_SIZE, PROT_READ | PROT_WRITE | PROT_EXEC,
                           MAP_ANON | MAP_PRIVATE, -1, 0);
    if (peek_cave_page == MAP_FAILED) {
        peek_cave_page = NULL;
        pthread_mutex_unlock(&install_mu);
        return 0;
    }
    cave = peek_cave_page;
    memset(cave, 0x90, PAGE_SIZE);
    memcpy(peek_stolen, fn, PEEK_STEAL);
    peek_addr = fn;

    cave[off++] = 0x50;
    cave[off++] = 0x51;
    cave[off++] = 0x52;
    cave[off++] = 0x56;
    cave[off++] = 0x57;
    cave[off++] = 0x41; cave[off++] = 0x50;
    cave[off++] = 0x41; cave[off++] = 0x51;
    cave[off++] = 0x48; cave[off++] = 0xb8;
    {
        void *fp = (void *)fly_peek_parent_poll;
        memcpy(cave + off, &fp, 8);
        off += 8;
    }
    cave[off++] = 0xff; cave[off++] = 0xd0;
    cave[off++] = 0x41; cave[off++] = 0x59;
    cave[off++] = 0x41; cave[off++] = 0x58;
    cave[off++] = 0x5f;
    cave[off++] = 0x5e;
    cave[off++] = 0x5a;
    cave[off++] = 0x59;
    cave[off++] = 0x58;
    memcpy(cave + off, peek_stolen, PEEK_STEAL);
    off += PEEK_STEAL;
    emit_jmp(cave + off, fn + PEEK_STEAL);

    if (make_rwx(fn, PEEK_STEAL) != 0) {
        spy_log("mprotect PeekMessage failed\n");
        pthread_mutex_unlock(&install_mu);
        return 0;
    }
    emit_jmp(fn, cave);
    peek_hooked = 1;
    spy_log("peek parent hooked @ %p -> cave %p getdcex=%d setdib=%d flush=%p upc=%d\n",
            (void *)fn, (void *)cave, p_GetDCEx ? 1 : 0, p_SetDIBits ? 1 : 0,
            (void *)p_flush_window_surfaces, is_upc_process());
    pthread_mutex_unlock(&install_mu);
    return 1;
}

static void *late_hook_thread(void *arg)
{
    int i;
    (void)arg;
    for (i = 0; i < 400 && !hooked; i++) {
        if (install_epi_hook()) break;
        usleep(50000);
    }
    if (!hooked)
        spy_log("FAILED epi hook after wait\n");
    for (i = 0; i < 400 && parent_present_enabled() && !peek_hooked; i++) {
        if (install_peek_parent_hook()) break;
        usleep(50000);
    }
    return NULL;
}

static void on_add_image(const struct mach_header *mh, intptr_t slide)
{
    Dl_info info;
    (void)slide;
    if (!dladdr(mh, &info) || !info.dli_fname) return;
    if (!strstr(info.dli_fname, "win32u.so")) return;
    if (!hooked) {
        spy_log("win32u.so loaded — epi hook\n");
        install_epi_hook();
    }
    if (parent_present_enabled() && !peek_hooked)
        install_peek_parent_hook();
}

__attribute__((constructor))
static void bridge_init(void)
{
    pthread_t th;
    const char *logp;

    ensure_label();
    if (strstr(proc_label, "wineserver")) return;

    logp = getenv("STRETCHBLT_SPY_LOG");
    spy_fd = open(logp && *logp ? logp : "/tmp/fly-stretch-epi.log",
                  O_WRONLY | O_CREAT | O_APPEND, 0644);

    spy_log("epi_bridge_init %s\n", proc_label);
    _dyld_register_func_for_add_image(on_add_image);
    if (!install_epi_hook()) {
        pthread_create(&th, NULL, late_hook_thread, NULL);
        pthread_detach(th);
    }
}
