/* present_force_inject.m — ObjC swizzle for Wine macdrv present path.
 * frankea winemac.so strips C symbols; swizzle Cocoa methods instead.
 *
 * clang -arch x86_64 -dynamiclib -o present_force_inject.dylib present_force_inject.m \
 *   -isysroot $(xcrun --sdk macosx --show-sdk-path) \
 *   -framework AppKit -framework QuartzCore -framework Foundation
 */
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <crt_externs.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <pthread.h>
#import <stdarg.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <errno.h>
#import <fcntl.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <sys/syscall.h>
#import <signal.h>
#import <time.h>
#import <unistd.h>

static FILE *logfp;
static pthread_mutex_t logmu = PTHREAD_MUTEX_INITIALIZER;
static int force_opaque = 1;
/* When set: on login-sized nil updateLayer, synthesize a solid CGImage and
 * call setColorImage — proves Cocoa view can show pixels without CEF flush. */
static int force_login_fill = 0;
/* Clear Cocoa per-pixel/shape on login-sized nil updateLayer (no solid fill). */
static int force_login_sync = 0;
/* When set: poll StretchBlt SRC bridge .bgra and push into setColorImage. */
static int force_login_bridge = 0;
static int force_surface_map = 0;
static int force_surface_map_post = 0; /* only after login bridge file exists */
static int force_parent_present = 0;
/* EA-only: FLY4 shm → setColorImage + hide WineMetalView. Connect stays off.
 * DXVK presents a cleared 520×867 WineMetalLayer on top of GDI SetDIBits. */
static int force_cocoa_fast = 0;
static int surface_map_post_dumps;
static char bridge_bgra_path[1024];
static int swizzle_done = 0;
static pthread_mutex_t swiz_mu = PTHREAD_MUTEX_INITIALIZER;
static char proc_label[256];
static int login_fill_done = 0;
static int login_sync_done = 0;
static int login_bridge_done = 0;
static long last_bridge_mtime_ns = -1;
static unsigned last_bridge_nz = 0;
static unsigned poll_mtime_same_sec;
static unsigned poll_apply_sec;
static long long poll_rate_bucket_ms;
static long long last_surface_map_ms;
static unsigned parent_present_ok;
static unsigned parent_present_fail;
static int is_upc_process = -1;

#define BRIDGE_MAGIC_V2 0x32594C46u
#define BRIDGE_MAGIC_V4 0x34594C46u
#define BRIDGE_SHM4_DEFAULT "/fly-upc-stretch-bridge4"
#define BRIDGE_SHM_MAX_W 2048
#define BRIDGE_SHM_MAX_H 1200
#define BRIDGE_SHM4_HDR 64
#define BRIDGE_SHM4_BYTES (BRIDGE_SHM4_HDR + (size_t)BRIDGE_SHM_MAX_W * (size_t)BRIDGE_SHM_MAX_H * 4)
#define DCX_CLIPSIBLINGS 0x00000010u
#define DIB_RGB_COLORS 0u
#define MTLH_MAGIC 0x4D544C48u /* MTLH */
#define MTLH_FILE "/tmp/fly-bnet-metal-host"

struct fly_mtlh {
    uint32_t magic;
    uint32_t context_id;
    uint32_t width, height;
    uint32_t owner_pid;
    uint32_t hwnd;       /* GET_SURFACE hwnd (GPU) */
    uint64_t view;       /* GPU-local NSView* from GET_SURFACE */
    uint32_t view_pid;
    uint32_t pad;
};

struct fly_shm4 {
    uint32_t magic;
    int32_t surf_w;
    int32_t surf_h;
    volatile uint32_t lock;
    uint64_t hwnd64;
    int32_t dx0, dy0, dx1, dy1;
    uint32_t seq;
    uint32_t gen;
    uint32_t owner_pid;
    uint32_t pad[3];
};

static void *shm4_map;
static unsigned last_shm4_seq;
static unsigned last_shm4_nz;
static __thread int in_cocoa_fast;
static int cocoa_metal_hidden;
static int cocoa_never_hide_metal;
static unsigned cocoa_collapse_hits;
static long long last_cocoa_good_ms;
static long long last_cocoa_log_ms;
static long long last_cocoa_apply_ms;
static long long last_ghost_log_ms;
static long long last_chrome_log_ms;
/* After login, EA leaves a 520×867 “EA” HWND. cocoa-fast used to restore +
 * orderFront it (13:55 0×0 path), so FLY4 of the library was squeezed into
 * that leftover and sat as a strip above the real 1536×781 window. */
static int cocoa_user_closed;
static int cocoa_library_mode;
static int cocoa_last_fw = 520;
static int cocoa_last_fh = 867;

typedef unsigned long ULONG_PTR;
typedef ULONG_PTR HANDLE;
typedef HANDLE HDC;
typedef HANDLE HWND;
typedef HANDLE HRGN;
typedef int INT;
typedef unsigned int UINT;
typedef unsigned int DWORD;

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

typedef HDC (*NtUserGetDCEx_fn)(HWND, HRGN, DWORD);
typedef INT (*NtUserReleaseDC_fn)(HWND, HDC);
typedef INT (*NtGdiSetDIBitsToDeviceInternal_fn)(HDC, INT, INT, DWORD, DWORD, INT, INT, UINT, UINT,
                                                 const void *, const BITMAPINFO *, UINT, UINT, UINT,
                                                 BOOL, void *);
typedef void (*flush_window_surfaces_fn)(BOOL);
typedef int (*NtUserPostMessage_fn)(HWND, unsigned, unsigned long, long);
typedef HWND (*NtUserSetFocus_fn)(HWND);
typedef HWND (*NtUserSetActiveWindow_fn)(HWND);
typedef HWND (*NtUserGetAncestor_fn)(HWND, unsigned);
typedef HWND (*NtUserWindowFromPoint_fn)(int, int);
typedef HWND (*NtUserSetCapture_fn)(HWND);
typedef unsigned (*NtUserSendInput_fn)(unsigned, void *, int);
typedef int (*NtUserSetWindowPos_fn)(HWND, HWND, int, int, int, int, unsigned);
typedef HWND (*NtUserSetParent_fn)(HWND, HWND);
typedef int (*NtUserShowWindow_fn)(HWND, int);

#define WM_SETFOCUS 0x0007
#define WM_KEYDOWN 0x0100
#define WM_KEYUP 0x0101
#define WM_CHAR 0x0102
#define WM_MOUSEMOVE 0x0200
#define WM_LBUTTONDOWN 0x0201
#define WM_LBUTTONUP 0x0202
#define WM_RBUTTONDOWN 0x0204
#define WM_RBUTTONUP 0x0205
#define WM_MOUSEWHEEL 0x020A
#define MK_LBUTTON 0x0001
#define MK_RBUTTON 0x0002
#define GA_ROOT 2

static NtUserGetDCEx_fn p_GetDCEx;
static NtUserReleaseDC_fn p_ReleaseDC;
static NtGdiSetDIBitsToDeviceInternal_fn p_SetDIBits;
static flush_window_surfaces_fn p_flush_window_surfaces;
static int parent_gdi_resolved;
static NtUserPostMessage_fn p_PostMessage;
static NtUserSetFocus_fn p_SetFocus;
static NtUserSetActiveWindow_fn p_SetActiveWindow;
static NtUserGetAncestor_fn p_GetAncestor;
static NtUserWindowFromPoint_fn p_WindowFromPoint;
static NtUserSetCapture_fn p_SetCapture;
static NtUserSendInput_fn p_SendInput;
static NtUserSetWindowPos_fn p_SetWindowPos;
static NtUserSetParent_fn p_SetParent;
static NtUserShowWindow_fn p_ShowWindow;
static int input_resolved;
static void *g_qt_hwnd;
static int g_hit_w, g_hit_h;
static int g_hit_logged;

#define HWND_TOP ((HWND)0)
#define SWP_SHOWWINDOW 0x0040u
#define SW_SHOW 5

#define INPUT_MOUSE 0
#define INPUT_KEYBOARD 1
#define MOUSEEVENTF_MOVE 0x0001
#define MOUSEEVENTF_LEFTDOWN 0x0002
#define MOUSEEVENTF_LEFTUP 0x0004
#define MOUSEEVENTF_RIGHTDOWN 0x0008
#define MOUSEEVENTF_RIGHTUP 0x0010
#define KEYEVENTF_KEYUP 0x0002
#define KEYEVENTF_UNICODE 0x0004

#pragma pack(push, 8)
typedef struct {
    uint32_t type;
    uint32_t pad;
    int32_t dx, dy;
    uint32_t mouseData, dwFlags, time, pad2;
    uint64_t extra;
} INPUT64;
#pragma pack(pop)

static void fly_surface_map_dump(const char *why);
static void try_swizzle(void);
static void fly_try_apply_bridge(void);
static void ensure_proc_label(void);
static void logmsg(const char *fmt, ...);
static CGImageRef fly_bgra_file_load(const char *path, unsigned *nz_out, int *w_out, int *h_out,
                                     void **bits_out, uint64_t *hwnd_out);

static void agent_log(const char *hid, const char *msg, const char *data_json)
{
    (void)hid;
    (void)msg;
    (void)data_json;
}

static long long inject_now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000LL + ts.tv_nsec / 1000000LL;
}

static void poll_rate_tick(void)
{
    /* #region agent log */
    long long now = inject_now_ms();
    char j[192];
    if (poll_rate_bucket_ms == 0) poll_rate_bucket_ms = now;
    if (now - poll_rate_bucket_ms < 1000) return;
    snprintf(j, sizeof(j),
             "{\"mtime_same_sec\":%u,\"apply_sec\":%u,\"last_nz\":%u}",
             poll_mtime_same_sec, poll_apply_sec, last_bridge_nz);
    agent_log("D", "bridge poll rate 1s", j);
    poll_mtime_same_sec = 0;
    poll_apply_sec = 0;
    poll_rate_bucket_ms = now;
    /* #endregion */
}

static CGImageRef fly_bgra_file_cgimage(const char *path, unsigned *nz_out, int *w_out, int *h_out)
{
    return fly_bgra_file_load(path, nz_out, w_out, h_out, NULL, NULL);
}

/* Load bridge .bgra — supports v1 (w,h,pixels) and v2 (FLY2,w,h,hwnd,pixels).
 * If bits_out non-NULL, caller owns malloc'd BGRA (no CGImage). */
static CGImageRef fly_bgra_file_load(const char *path, unsigned *nz_out, int *w_out, int *h_out,
                                     void **bits_out, uint64_t *hwnd_out)
{
    FILE *f;
    int32_t w = 0, h = 0;
    uint32_t magic = 0;
    uint64_t hwnd64 = 0;
    size_t n, nbytes, got, hdr;
    long fsz;
    void *buf;
    uint32_t *p;
    unsigned nz = 0;
    CGColorSpaceRef cs;
    CGContextRef ctx;
    CGImageRef img;

    if (nz_out) *nz_out = 0;
    if (w_out) *w_out = 0;
    if (h_out) *h_out = 0;
    if (bits_out) *bits_out = NULL;
    if (hwnd_out) *hwnd_out = 0;
    f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    fsz = ftell(f);
    if (fseek(f, 0, SEEK_SET) != 0) { fclose(f); return NULL; }
    if (fread(&magic, 4, 1, f) != 1) { fclose(f); return NULL; }
    if (magic == BRIDGE_MAGIC_V2) {
        if (fread(&w, 4, 1, f) != 1 || fread(&h, 4, 1, f) != 1 || fread(&hwnd64, 8, 1, f) != 1) {
            fclose(f);
            return NULL;
        }
        hdr = 20;
    } else {
        /* v1: first dword was width */
        w = (int32_t)magic;
        if (fread(&h, 4, 1, f) != 1) { fclose(f); return NULL; }
        hdr = 8;
    }
    if (w < 8 || h < 8 || w > 8192 || h > 8192) {
        fclose(f);
        return NULL;
    }
    n = (size_t)w * (size_t)h;
    nbytes = n * 4;
    if (fsz >= 0 && (size_t)fsz != hdr + nbytes) {
        /* size mismatch — still try read */
    }
    buf = malloc(nbytes);
    if (!buf) { fclose(f); return NULL; }
    got = fread(buf, 1, nbytes, f);
    fclose(f);
    if (got != nbytes) { free(buf); return NULL; }
    p = (uint32_t *)buf;
    for (size_t i = 0; i < n; i++) {
        if (p[i] & 0x00FFFFFFu) nz++;
        p[i] |= 0xFF000000u;
    }
    if (nz_out) *nz_out = nz;
    if (w_out) *w_out = w;
    if (h_out) *h_out = h;
    if (hwnd_out) *hwnd_out = hwnd64;

    if (bits_out) {
        *bits_out = buf;
        return NULL; /* caller owns bits; no CGImage */
    }

    cs = CGColorSpaceCreateDeviceRGB();
    ctx = CGBitmapContextCreate(buf, (size_t)w, (size_t)h, 8, (size_t)w * 4, cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    img = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    if (ctx) CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    free(buf);
    return img;
}

static const char *shm4_name(void)
{
    const char *e = getenv("FLY_BRIDGE_SHM4_NAME");
    if (e && e[0] == '/')
        return e;
    return BRIDGE_SHM4_DEFAULT;
}

static struct fly_shm4 *shm4_map_ro(void)
{
    int fd;
    void *p;
    if (shm4_map)
        return (struct fly_shm4 *)shm4_map;
    fd = shm_open(shm4_name(), O_RDWR, 0666);
    if (fd < 0)
        return NULL;
    p = mmap(NULL, BRIDGE_SHM4_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED)
        return NULL;
    shm4_map = p;
    return (struct fly_shm4 *)p;
}

static int shm4_trylock(struct fly_shm4 *sh)
{
    int spins = 0;
    while (!__sync_bool_compare_and_swap(&sh->lock, 0u, 1u)) {
        if (++spins > 20000)
            return 0;
    }
    return 1;
}

/* Full FLY4 surface as CGImage. Same pixels the epi hook already replayed. */
static CGImageRef fly_shm4_cgimage(unsigned *nz_out, int *w_out, int *h_out)
{
    struct fly_shm4 *sh;
    uint32_t *shadow, *copy;
    int w, h, x, y;
    unsigned nz = 0;
    size_t n;
    CGColorSpaceRef cs;
    CGContextRef ctx;
    CGImageRef img;

    if (nz_out) *nz_out = 0;
    if (w_out) *w_out = 0;
    if (h_out) *h_out = 0;
    sh = shm4_map_ro();
    if (!sh || sh->magic != BRIDGE_MAGIC_V4)
        return NULL;
    if (sh->surf_w < 8 || sh->surf_h < 8 || sh->surf_w > BRIDGE_SHM_MAX_W ||
        sh->surf_h > BRIDGE_SHM_MAX_H)
        return NULL;
    if (!shm4_trylock(sh))
        return NULL;
    w = sh->surf_w;
    h = sh->surf_h;
    n = (size_t)w * (size_t)h;
    copy = (uint32_t *)malloc(n * 4);
    if (!copy) {
        sh->lock = 0;
        return NULL;
    }
    shadow = (uint32_t *)((uint8_t *)sh + BRIDGE_SHM4_HDR);
    memcpy(copy, shadow, n * 4);
    last_shm4_seq = sh->seq;
    sh->lock = 0;
    for (y = 0; y < h; y++) {
        for (x = 0; x < w; x++) {
            uint32_t px = copy[(size_t)y * w + x];
            if (px & 0x00FFFFFFu)
                nz++;
            copy[(size_t)y * w + x] = px | 0xFF000000u;
        }
    }
    last_shm4_nz = nz;
    if (nz_out) *nz_out = nz;
    if (w_out) *w_out = w;
    if (h_out) *h_out = h;
    if (nz < 64) {
        free(copy);
        return NULL;
    }
    cs = CGColorSpaceCreateDeviceRGB();
    ctx = CGBitmapContextCreate(copy, (size_t)w, (size_t)h, 8, (size_t)w * 4, cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    img = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    if (ctx) CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    free(copy);
    return img;
}

static int fly_cocoa_rate(long long *last, long long min_ms)
{
    long long now = inject_now_ms();
    if (*last && now - *last < min_ms)
        return 0;
    *last = now;
    return 1;
}

static int fly_is_ea_title(NSWindow *w)
{
    return w && w.title && [w.title isEqualToString:@"EA"];
}

static int fly_window_login_sized(NSWindow *w)
{
    CGFloat bw, bh;
    if (!w)
        return 0;
    bw = w.frame.size.width;
    bh = w.frame.size.height;
    return (bw >= 400.0 && bw <= 800.0 && bh >= 600.0 && bh <= 1100.0);
}

static int fly_view_is_ea_login(NSView *view)
{
    CGFloat bw, bh;
    NSWindow *win;
    if (!view)
        return 0;
    win = view.window;
    if (fly_is_ea_title(win))
        return 1;
    bw = view.bounds.size.width;
    bh = view.bounds.size.height;
    if (bw < 1.0 || bh < 1.0) {
        bw = view.layer ? view.layer.bounds.size.width : bw;
        bh = view.layer ? view.layer.bounds.size.height : bh;
    }
    /* EA login is 520×867. Connect hub is 1454×934 — FLY_COCOA_FAST is EA-only. */
    return (bw >= 400.0 && bw <= 800.0 && bh >= 600.0 && bh <= 1100.0);
}

/* Library HWND after login. Never pick the leftover 520×867 once we have seen
 * a ≥900-wide “EA” window (17:41 ghost strip). */
static NSWindow *fly_primary_ea_window(void)
{
    NSWindow *best = nil;
    CGFloat bestArea = -1.0;
    for (NSWindow *win in [NSApplication sharedApplication].windows) {
        CGFloat a;
        if (!fly_is_ea_title(win))
            continue;
        if (cocoa_library_mode && fly_window_login_sized(win))
            continue;
        a = win.frame.size.width * win.frame.size.height;
        if (a > bestArea) {
            bestArea = a;
            best = win;
        }
    }
    return best;
}

static int fly_window_is_primary_ea(NSWindow *w)
{
    NSWindow *best;
    if (!w || cocoa_user_closed)
        return 0;
    best = fly_primary_ea_window();
    return best && w == best;
}

static void fly_order_out_all_ea(void)
{
    for (NSWindow *win in [NSApplication sharedApplication].windows) {
        if (fly_is_ea_title(win) || fly_window_login_sized(win))
            [win orderOut:nil];
    }
}

static void fly_order_out_ea_ghosts(NSWindow *keep)
{
    if (!keep || !cocoa_library_mode)
        return;
    for (NSWindow *win in [NSApplication sharedApplication].windows) {
        if (win == keep)
            continue;
        if (!fly_is_ea_title(win) && !fly_window_login_sized(win))
            continue;
        if (win.isVisible || win.frame.size.width >= 80.0) {
            [win orderOut:nil];
            if (fly_cocoa_rate(&last_ghost_log_ms, 1000))
                logmsg("cocoa-fast ghost orderOut %p frame=%.0fx%.0f keep=%.0fx%.0f\n",
                       win, win.frame.size.width, win.frame.size.height,
                       keep.frame.size.width, keep.frame.size.height);
        }
    }
}

static void fly_ensure_ea_chrome(NSWindow *w)
{
    NSWindowStyleMask want, have;
    NSButton *btn;
    if (!w || cocoa_user_closed)
        return;
    want = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
           NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
           NSWindowStyleMaskFullSizeContentView;
    have = w.styleMask;
    if ((have & (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)) !=
        (NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)) {
        w.styleMask = have | want;
        if (fly_cocoa_rate(&last_chrome_log_ms, 2000))
            logmsg("cocoa-fast chrome styleMask was=%lu now=%lu win=%p frame=%.0fx%.0f\n",
                   (unsigned long)have, (unsigned long)w.styleMask, w,
                   w.frame.size.width, w.frame.size.height);
    }
    w.titlebarAppearsTransparent = YES;
    w.titleVisibility = NSWindowTitleHidden;
    btn = [w standardWindowButton:NSWindowCloseButton];
    if (btn)
        btn.hidden = NO;
    btn = [w standardWindowButton:NSWindowMiniaturizeButton];
    if (btn)
        btn.hidden = NO;
    btn = [w standardWindowButton:NSWindowZoomButton];
    if (btn)
        btn.hidden = NO;
}

static void fly_user_close_ea(NSWindow *w)
{
    if (cocoa_user_closed)
        return;
    cocoa_user_closed = 1;
    logmsg("cocoa-fast user close win=%p frame=%.0fx%.0f pid=%d\n",
           w, w ? w.frame.size.width : 0, w ? w.frame.size.height : 0, (int)getpid());
    fly_order_out_all_ea();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        logmsg("cocoa-fast SIGTERM after close\n");
        kill(getpid(), SIGTERM);
    });
}

static int fly_metal_present_count(NSWindow *w)
{
    Class metalViewCls, metalLayerCls, caMetalCls;
    NSView *cv;
    NSMutableArray<NSView *> *stack;
    int n = 0;
    if (!w)
        return 0;
    metalViewCls = NSClassFromString(@"WineMetalView");
    metalLayerCls = NSClassFromString(@"WineMetalLayer");
    caMetalCls = NSClassFromString(@"CAMetalLayer");
    cv = w.contentView;
    if (!cv)
        return 0;
    stack = [NSMutableArray arrayWithObject:cv];
    for (NSUInteger i = 0; i < stack.count; i++) {
        NSView *v = stack[i];
        if (v.subviews.count)
            [stack addObjectsFromArray:v.subviews];
        if (metalViewCls && [v isKindOfClass:metalViewCls])
            n++;
        else if (v.layer && metalLayerCls && [v.layer isKindOfClass:metalLayerCls])
            n++;
        else if (v.layer && caMetalCls && [v.layer isKindOfClass:caMetalCls])
            n++;
    }
    return n;
}

static void fly_raise_metal_views(NSWindow *w)
{
    Class metalCls;
    NSView *cv;
    NSMutableArray<NSView *> *stack;
    if (!w)
        return;
    metalCls = NSClassFromString(@"WineMetalView");
    cv = w.contentView;
    if (!cv)
        return;
    stack = [NSMutableArray arrayWithObject:cv];
    for (NSUInteger i = 0; i < stack.count; i++) {
        NSView *v = stack[i];
        if (v.subviews.count)
            [stack addObjectsFromArray:v.subviews];
        if (metalCls && [v isKindOfClass:metalCls]) {
            v.hidden = NO;
            if (v.superview)
                [v.superview addSubview:v positioned:NSWindowAbove relativeTo:nil];
        }
    }
}

static int fly_bnet_argv_has(const char *needle)
{
    int argc, i;
    char **argv = *_NSGetArgv();

    argc = *_NSGetArgc();
    if (!argv || !needle)
        return 0;
    for (i = 0; i < argc; i++) {
        if (argv[i] && strcasestr(argv[i], needle))
            return 1;
    }
    return 0;
}

/* Path `…/Battle.net/Agent/Agent.exe` contains "Battle.net" — R21
 * restore/host ran on the Agent HWND (1432×700) and the client died. */
static int fly_is_bnet_gpu(void)
{
    return fly_bnet_argv_has("Battle.net.exe") &&
           fly_bnet_argv_has("--type=gpu-process");
}

static int fly_is_bnet_parent(void)
{
    if (fly_bnet_argv_has("Agent.exe") || fly_bnet_argv_has("Agent."))
        return 0;
    return fly_bnet_argv_has("Battle.net.exe") && !fly_bnet_argv_has("--type=");
}

/* macdrv run_cocoa_app: if NSApp already exists and is not WineApplication,
 * setWineController: is missing → macdrv_init "Failed to start Cocoa app
 * main loop". [NSApplication sharedApplication] *creates* a vanilla NSApp.
 * Connect never walks windows before upc's macdrv is up. Battle.net waits
 * on Agent, so the 0.4s host timer used to own Cocoa first. */
static NSArray<NSWindow *> *fly_wine_nsapp_windows(void)
{
    Class wineApp = NSClassFromString(@"WineApplication");
    if (!NSApp)
        return nil;
    if (wineApp && ![NSApp isKindOfClass:wineApp])
        return nil;
    return NSApp.windows;
}

/* Round 12: regular file + raw syscall. Wine interposes libc shm_open/open. */
static long raw_syscall6(long n, long a1, long a2, long a3, long a4, long a5, long a6)
{
    long ret;
    register int64_t r10 asm("r10") = a4;
    register int64_t r8 asm("r8") = a5;
    register int64_t r9 asm("r9") = a6;

    __asm__ volatile("syscall"
                     : "=a"(ret)
                     : "a"(n | 0x2000000L), "D"(a1), "S"(a2), "d"(a3),
                       "r"(r10), "r"(r8), "r"(r9)
                     : "rcx", "r11", "cc", "memory");
    return ret;
}

static int mtlh_sys_open(int create)
{
    return (int)raw_syscall6(SYS_open, (long)MTLH_FILE,
                             create ? (O_RDWR | O_CREAT) : O_RDWR, 0600, 0, 0, 0);
}

static int mtlh_sys_read(struct fly_mtlh *out)
{
    int fd;
    long n;

    fd = mtlh_sys_open(1);
    if (fd < 0)
        return -1;
    (void)raw_syscall6(SYS_ftruncate, fd, 4096, 0, 0, 0, 0);
    n = raw_syscall6(SYS_pread, fd, (long)out, (long)sizeof(*out), 0, 0, 0);
    (void)raw_syscall6(SYS_close, fd, 0, 0, 0, 0, 0);
    return n < 0 ? -1 : 0;
}

static int mtlh_sys_write(const struct fly_mtlh *in)
{
    int fd;
    long n;

    fd = mtlh_sys_open(1);
    if (fd < 0)
        return -1;
    (void)raw_syscall6(SYS_ftruncate, fd, 4096, 0, 0, 0, 0);
    n = raw_syscall6(SYS_pwrite, fd, (long)in, (long)sizeof(*in), 0, 0, 0);
    (void)raw_syscall6(SYS_close, fd, 0, 0, 0, 0, 0);
    return n < (long)sizeof(*in) ? -1 : 0;
}

static struct fly_mtlh fly_mtlh_buf;

static struct fly_mtlh *fly_mtlh_map(int create)
{
    (void)create;
    if (mtlh_sys_read(&fly_mtlh_buf) != 0)
        return NULL;
    return &fly_mtlh_buf;
}

static void fly_mtlh_flush(void)
{
    if (mtlh_sys_write(&fly_mtlh_buf) != 0)
        logmsg("mtlh: syscall pwrite %s failed\n", MTLH_FILE);
}

/* CALayerHost is paint-only. R17: off-screen helper WineWindow + 
 * WineEventQueue postEvent / postKey so unix thread delivers to CEF.
 * Do not cover paint. Do not call unix macdrv_mouse_button on main. */
static int fly_cef_hwnd(void)
{
    struct fly_mtlh *m = fly_mtlh_map(0);
    if (!m || m->magic != MTLH_MAGIC || !m->hwnd)
        return 0;
    return (int)m->hwnd;
}

static void *fly_wine_hwnd(NSWindow *w)
{
    Class wineWinCls = NSClassFromString(@"WineWindow");
    Ivar ih;

    if (!w)
        return NULL;
    ih = class_getInstanceVariable(object_getClass(w), "hwnd");
    if (!ih && wineWinCls)
        ih = class_getInstanceVariable(wineWinCls, "hwnd");
    if (ih)
        return *(void **)((char *)(__bridge void *)w + ivar_getOffset(ih));
    return NULL;
}

#define MACDRV_MOUSE_BUTTON 11
#define MACDRV_KEY_PRESS 7
#define MACDRV_KEY_RELEASE 8

static NSWindow *g_cef_cocoa;
static int g_cef_cocoa_hwnd;
static id g_cef_queue;
static NSWindow *g_qt_win;

static id fly_wine_queue(NSWindow *w)
{
    id queue = nil;

    if (!w)
        return nil;
    if ([w respondsToSelector:@selector(queue)])
        queue = ((id (*)(id, SEL))objc_msgSend)(w, @selector(queue));
    if (!queue) {
        @try {
            queue = [w valueForKey:@"queue"];
        } @catch (NSException *e) {
            queue = nil;
        }
    }
    return queue;
}

/* Off-screen helper only — never addChildWindow / orderFront (R16 covered paint). */
static void fly_attach_cef_cocoa(NSWindow *qt)
{
    int cef;
    Class WC;
    id queue;
    NSRect frame;
    uint32_t features = 0;
    SEL createSel;
    NSWindow *helper;

    if (!qt || force_cocoa_fast || !fly_is_bnet_parent())
        return;
    cef = fly_cef_hwnd();
    if (!cef)
        return;
    WC = NSClassFromString(@"WineWindow");
    if (!WC)
        return;
    queue = fly_wine_queue(qt);
    g_qt_win = qt;
    g_cef_queue = queue;
    if (g_cef_cocoa) {
        if (g_cef_cocoa_hwnd != cef && [g_cef_cocoa respondsToSelector:@selector(setHwnd:)])
            ((void (*)(id, SEL, void *))objc_msgSend)(g_cef_cocoa, @selector(setHwnd:),
                                                      (void *)(uintptr_t)(unsigned)cef);
        g_cef_cocoa_hwnd = cef;
        [g_cef_cocoa orderOut:nil];
        g_cef_cocoa.ignoresMouseEvents = YES;
        g_cef_cocoa.alphaValue = 0;
        return;
    }
    frame = NSMakeRect(-8000, -8000, 8, 8);
    createSel = NSSelectorFromString(@"createWindowWithFeatures:windowFrame:hwnd:queue:");
    helper = nil;
    if ([WC respondsToSelector:createSel])
        helper = ((id (*)(id, SEL, const void *, NSRect, void *, id))objc_msgSend)(
            WC, createSel, &features, frame, (void *)(uintptr_t)(unsigned)cef, queue);
    if (!helper) {
        helper = [[WC alloc] initWithContentRect:NSMakeRect(0, 0, 8, 8)
                                       styleMask:NSWindowStyleMaskBorderless
                                         backing:NSBackingStoreBuffered
                                           defer:YES];
        if ([helper respondsToSelector:@selector(setHwnd:)])
            ((void (*)(id, SEL, void *))objc_msgSend)(helper, @selector(setHwnd:),
                                                      (void *)(uintptr_t)(unsigned)cef);
        if (queue && [helper respondsToSelector:@selector(setQueue:)])
            ((void (*)(id, SEL, id))objc_msgSend)(helper, @selector(setQueue:), queue);
        [helper setFrame:frame display:NO];
    }
    helper.ignoresMouseEvents = YES;
    helper.alphaValue = 0;
    helper.hasShadow = NO;
    [helper orderOut:nil];
    g_cef_cocoa = helper;
    g_cef_cocoa_hwnd = cef;
    CFRetain((__bridge CFTypeRef)helper);
    logmsg("mtlh: cef offscreen hwnd=0x%x helper=%p qt=%p queue=%p\n",
           cef, helper, qt, queue);
}

static void fly_wine_screen_xy(NSView *view, NSEvent *ev, int *ox, int *oy)
{
    NSWindow *w;
    NSPoint p;
    NSRect sr, sf;

    *ox = 0;
    *oy = 0;
    if (!view || !ev)
        return;
    w = view.window ?: g_qt_win;
    if (!w)
        return;
    p = [ev locationInWindow];
    sr = [w convertRectToScreen:NSMakeRect(p.x, p.y, 1, 1)];
    sf = (w.screen ?: [NSScreen mainScreen]).frame;
    *ox = (int)sr.origin.x;
    *oy = (int)((sf.origin.y + sf.size.height) - sr.origin.y);
}

/* postEvent: is Cocoa → unix queue. Not unix macdrv_mouse_button on main. */
static int fly_queue_cef_mouse(NSView *view, NSEvent *ev, int button, int pressed)
{
    unsigned char *buf;
    int x, y, cef;
    id queue;

    if (force_cocoa_fast || !fly_is_bnet_parent() || !ev)
        return 0;
    cef = fly_cef_hwnd();
    if (!cef || !g_cef_cocoa)
        return 0;
    queue = g_cef_queue ?: fly_wine_queue(view.window);
    if (!queue || ![queue respondsToSelector:@selector(postEvent:)])
        return 0;
    fly_wine_screen_xy(view, ev, &x, &y);
    buf = calloc(1, 64);
    if (!buf)
        return 0;
    *(int *)(buf + 0) = 1;
    *(int *)(buf + 8) = MACDRV_MOUSE_BUTTON;
    *(void **)(buf + 16) = (__bridge void *)g_cef_cocoa;
    *(int *)(buf + 24) = button;
    buf[28] = (unsigned char)(pressed ? 1 : 0);
    *(int *)(buf + 32) = x;
    *(int *)(buf + 36) = y;
    *(uint64_t *)(buf + 40) = (uint64_t)(ev.timestamp * 1000.0);
    ((void (*)(id, SEL, void *))objc_msgSend)(queue, @selector(postEvent:), buf);
    {
        static long long last;
        if (fly_cocoa_rate(&last, 200))
            logmsg("mtlh: queue postEvent MOUSE hwnd=0x%x btn=%d press=%d scr=%d,%d\n",
                   cef, button, pressed, x, y);
    }
    return 1;
}

static int fly_queue_cef_key(NSEvent *ev, int down)
{
    int cef;
    SEL sel;

    if (force_cocoa_fast || !fly_is_bnet_parent() || !ev || !g_cef_cocoa)
        return 0;
    cef = fly_cef_hwnd();
    if (!cef)
        return 0;
    sel = @selector(postKey:pressed:modifiers:event:);
    if ([g_cef_cocoa respondsToSelector:sel]) {
        ((void (*)(id, SEL, unsigned short, char, unsigned long long, id))objc_msgSend)(
            g_cef_cocoa, sel, (unsigned short)ev.keyCode, (char)(down ? 1 : 0),
            (unsigned long long)ev.modifierFlags, ev);
    } else if ([g_cef_cocoa respondsToSelector:@selector(postKeyEvent:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(g_cef_cocoa, @selector(postKeyEvent:), ev);
    } else {
        return 0;
    }
    {
        static long long last;
        if (fly_cocoa_rate(&last, 200))
            logmsg("mtlh: queue postKey hwnd=0x%x down=%d vk=0x%x\n",
                   cef, down, (unsigned)ev.keyCode);
    }
    return 1;
}

static void fly_post_cef(int hwnd, unsigned msg, unsigned long wp, long lp)
{
    HWND h = (HWND)(uintptr_t)(unsigned)hwnd;
    uint32_t hwflags = 0;

    if (!h)
        return;
    if (msg == WM_LBUTTONDOWN)
        hwflags = MOUSEEVENTF_LEFTDOWN;
    else if (msg == WM_LBUTTONUP)
        hwflags = MOUSEEVENTF_LEFTUP;
    else if (msg == WM_RBUTTONDOWN)
        hwflags = MOUSEEVENTF_RIGHTDOWN;
    else if (msg == WM_RBUTTONUP)
        hwflags = MOUSEEVENTF_RIGHTUP;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        INPUT64 in;
        HWND root;
        unsigned sent = 0;

        if (p_SetCapture && (hwflags & (MOUSEEVENTF_LEFTDOWN | MOUSEEVENTF_RIGHTDOWN)))
            p_SetCapture(h);
        if (p_SetFocus)
            p_SetFocus(h);
        if (p_GetAncestor && p_SetActiveWindow) {
            root = p_GetAncestor(h, GA_ROOT);
            if (root)
                p_SetActiveWindow(root);
        }
        if (p_SendInput && hwflags) {
            memset(&in, 0, sizeof(in));
            in.type = INPUT_MOUSE;
            in.dwFlags = hwflags;
            sent = p_SendInput(1, &in, (int)sizeof(in));
        }
        if (p_PostMessage)
            p_PostMessage(h, msg, wp, lp);
        /* Keep capture on the CEF hwnd so Wine hardware input stays there. */
        if (msg == WM_LBUTTONDOWN || msg == WM_CHAR) {
            static long long last;
            if (fly_cocoa_rate(&last, 200))
                logmsg("mtlh: hw hwnd=0x%x msg=0x%x sendinput=%u flags=0x%x\n",
                       hwnd, msg, sent, hwflags);
        }
    });
}

static int fly_forward_cef_mouse(NSView *view, NSEvent *ev, unsigned msg, unsigned mk)
{
    NSWindow *w;
    NSPoint p;
    NSRect b;
    struct fly_mtlh *m;
    int hwnd, cw, ch, cx, cy;
    long lp;

    if (force_cocoa_fast || !view || !ev)
        return 0;
    m = fly_mtlh_map(0);
    if (!m || m->magic != MTLH_MAGIC || !m->hwnd)
        return 0;
    hwnd = (int)m->hwnd;
    w = view.window;
    if (!w)
        return 0;
    p = [ev locationInWindow];
    b = view.bounds;
    if (b.size.width < 8 || b.size.height < 8)
        return 0;
    /* Cocoa origin is bottom-left; Win32 client is top-left. Hosted
     * layer fills the content view — map linearly onto CEF client. */
    cw = m->width > 8 ? (int)m->width : (int)b.size.width;
    ch = m->height > 8 ? (int)m->height : (int)b.size.height;
    cx = (int)(p.x * (double)cw / b.size.width);
    cy = (int)((b.size.height - p.y) * (double)ch / b.size.height);
    if (cx < 0) cx = 0;
    if (cy < 0) cy = 0;
    if (cx > cw) cx = cw;
    if (cy > ch) cy = ch;
    lp = ((cy & 0xffff) << 16) | (cx & 0xffff);
    {
        static long long last;
        if (fly_cocoa_rate(&last, 200))
            logmsg("mtlh: input hwnd=0x%x msg=0x%x client=%d,%d view=%.0fx%.0f cef=%dx%d\n",
                   hwnd, msg, cx, cy, b.size.width, b.size.height, cw, ch);
    }
    fly_post_cef(hwnd, msg, mk, lp);
    (void)w;
    return 1;
}

static int fly_forward_cef_key(NSEvent *ev, int down)
{
    int hwnd;
    NSString *chars;
    NSUInteger i, n;

    hwnd = fly_cef_hwnd();
    if (!hwnd || !ev)
        return 0;
    if (down) {
        unsigned short vk = (unsigned short)ev.keyCode;
        fly_post_cef(hwnd, WM_KEYDOWN, vk, 0);
        chars = ev.characters;
        n = chars.length;
        for (i = 0; i < n; i++) {
            unichar c = [chars characterAtIndex:i];
            if (c >= 32)
                fly_post_cef(hwnd, WM_CHAR, c, 0);
        }
    } else {
        fly_post_cef(hwnd, WM_KEYUP, (unsigned short)ev.keyCode, 0);
    }
    {
        static long long last;
        if (fly_cocoa_rate(&last, 200))
            logmsg("mtlh: key hwnd=0x%x down=%d vk=%u\n", hwnd, down, (unsigned)ev.keyCode);
    }
    return 1;
}

static uint32_t fly_cgs_main(void)
{
    static uint32_t (*fn)(void);
    if (!fn) {
        void *h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        if (!h)
            h = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY);
        if (h)
            fn = dlsym(h, "CGSMainConnectionID");
    }
    return fn ? fn() : 0;
}

/* Metal layer on the GET_SURFACE view (and its subviews). Do not walk
 * NSApplication.windows — GPU has wins=0; the view is an orphan. */
static CALayer *fly_metal_layer_on_view(NSView *root)
{
    NSMutableArray<NSView *> *stack;
    Class metalView = NSClassFromString(@"WineMetalView");
    Class metalLayer = NSClassFromString(@"WineMetalLayer");
    Class caMetal = NSClassFromString(@"CAMetalLayer");
    NSUInteger i;

    if (!root)
        return nil;
    stack = [NSMutableArray arrayWithObject:root];
    for (i = 0; i < stack.count; i++) {
        NSView *v = stack[i];
        CALayer *L;

        if (v.subviews.count)
            [stack addObjectsFromArray:v.subviews];
        L = v.layer;
        if (!L)
            continue;
        if (metalLayer && [L isKindOfClass:metalLayer])
            return L;
        if (caMetal && [L isKindOfClass:caMetal])
            return L;
        if (metalView && [v isKindOfClass:metalView])
            return L;
    }
    return nil;
}

/* GPU process: CAContext the GET_SURFACE view* from /fly-bnet-metal-host
 * (winemac_rtld_global writes it). Parent CALayerHosts contextId onto Qt. */
static void fly_publish_gpu_metal(void)
{
    static int published;
    NSView *mv = nil;
    CALayer *layer = nil;
    Class ctxCls;
    id ctx = nil;
    uint32_t cid = 0;
    struct fly_mtlh *shm;
    uint32_t cgs;

    static uint64_t published_view;
    static uint32_t published_hwnd;

    if (!fly_is_bnet_gpu())
        return;
    shm = fly_mtlh_map(1);
    if (published && shm && shm->view == published_view && shm->hwnd == published_hwnd)
        return;
    if (!shm || shm->magic != MTLH_MAGIC || !shm->view ||
        shm->view_pid != (uint32_t)getpid()) {
        static long long last;
        if (fly_cocoa_rate(&last, 800))
            logmsg("mtlh: gpu no GET_SURFACE view yet magic=%x view=%llx vpid=%u me=%d\n",
                   shm ? shm->magic : 0, shm ? (unsigned long long)shm->view : 0,
                   shm ? shm->view_pid : 0, (int)getpid());
        return;
    }
    @try {
        mv = (__bridge NSView *)(void *)(uintptr_t)shm->view;
        if (![mv isKindOfClass:[NSView class]]) {
            static long long last;
            if (fly_cocoa_rate(&last, 800))
                logmsg("mtlh: GET_SURFACE view=%p not NSView hwnd=0x%x\n",
                       mv, shm->hwnd);
            return;
        }
        layer = fly_metal_layer_on_view(mv);
    } @catch (NSException *e) {
        logmsg("mtlh: GET_SURFACE view EXC %s\n", e.description.UTF8String);
        return;
    }
    if (!layer) {
        static long long last;
        if (fly_cocoa_rate(&last, 800))
            logmsg("mtlh: GET_SURFACE view=%p hwnd=0x%x no metal layer yet subs=%lu\n",
                   mv, shm->hwnd, (unsigned long)mv.subviews.count);
        return;
    }
    ctxCls = NSClassFromString(@"CAContext");
    cgs = fly_cgs_main();
    if (ctxCls && cgs) {
        SEL sel = sel_registerName("contextWithCGSConnection:options:");
        if ([ctxCls respondsToSelector:sel])
            ctx = ((id (*)(id, SEL, uint32_t, id))objc_msgSend)(ctxCls, sel, cgs, @{});
    }
    if (!ctx && ctxCls) {
        SEL sel = sel_registerName("remoteContextWithOptions:");
        if ([ctxCls respondsToSelector:sel])
            ctx = ((id (*)(id, SEL, id))objc_msgSend)(ctxCls, sel, @{});
    }
    if (!ctx) {
        logmsg("mtlh: CAContext create failed cgs=%u cls=%p\n", cgs, ctxCls);
        return;
    }
    @try {
        [ctx setValue:layer forKey:@"layer"];
        cid = [[ctx valueForKey:@"contextId"] unsignedIntValue];
    } @catch (NSException *e) {
        logmsg("mtlh: CAContext set layer EXC %s\n", e.description.UTF8String);
        return;
    }
    if (!cid) {
        logmsg("mtlh: contextId=0 layer=%p\n", layer);
        return;
    }
    shm->magic = MTLH_MAGIC;
    shm->context_id = cid;
    shm->width = (uint32_t)mv.bounds.size.width;
    shm->height = (uint32_t)mv.bounds.size.height;
    shm->owner_pid = (uint32_t)getpid();
    fly_mtlh_flush();
    CFRetain((__bridge CFTypeRef)ctx);
    published = 1;
    published_view = shm->view;
    published_hwnd = shm->hwnd;
    logmsg("mtlh: published contextId=%u view=%p layer=%p %ux%u hwnd=0x%x pid=%d file=%s\n",
           cid, mv, layer, shm->width, shm->height, shm->hwnd, (int)getpid(), MTLH_FILE);
}

/* Login CEF is tall ~362×631/719. Post-login HostedFlow / Home is the
 * current presenting HWND (often square ~392×391, later larger). Host
 * Metal onto whichever window is painting — not only the first tall one. */
static int fly_bnet_present_win(NSWindow *w, size_t iw, size_t ih)
{
    CGFloat wf = w ? w.frame.size.width : 0;
    CGFloat hf = w ? w.frame.size.height : 0;

    if (wf >= 200 && hf >= 200)
        return 1;
    if (iw >= 200 && ih >= 200)
        return 1;
    return 0;
}

static NSWindow *g_host_win;

/* EA 17:50 / Connect ghost: leftover login HWND + stacked hosts.
 * Do not add a second CALayerHost; do not composite login-sized Metal
 * (376×344 HostedFlow / 348×646 login) onto Home — that is the nav strip. */
static void fly_remove_layer_hosts(NSView *cv)
{
    Class hostCls;
    NSArray<CALayer *> *subs;

    hostCls = NSClassFromString(@"CALayerHost");
    if (!hostCls || !cv || !cv.layer || !cv.layer.sublayers)
        return;
    subs = [cv.layer.sublayers copy];
    for (CALayer *L in subs) {
        if ([L isKindOfClass:hostCls])
            [L removeFromSuperlayer];
    }
}

/* True Home is ~1600×976 (R18). Splash/update ~1434×702 is not Home —
 * treating it as Home orderOut the login (R20 first Play). */
static int fly_bnet_home_win(NSWindow *w)
{
    return w && w.frame.size.width >= 1500.0 && w.frame.size.height >= 800.0;
}

static int fly_mtlh_small_for_home(struct fly_mtlh *shm, NSWindow *w)
{
    if (!shm || !w || !fly_bnet_home_win(w))
        return 0;
    if (!shm->width || !shm->height)
        return 0;
    return (shm->width < 600 || shm->height < 400);
}

static int fly_host_gpu_metal(NSWindow *w)
{
    static int hosted;
    static uint32_t last_cid;
    struct fly_mtlh *shm;
    Class hostCls;
    CALayer *host;
    NSView *cv;

    if (!w || force_cocoa_fast)
        return 0;
    shm = fly_mtlh_map(0);
    if (!shm || shm->magic != MTLH_MAGIC || !shm->context_id)
        return hosted && last_cid && w == g_host_win;
    if (shm->owner_pid && kill((pid_t)shm->owner_pid, 0) != 0)
        return hosted && last_cid && w == g_host_win;
    if (hosted && last_cid == shm->context_id && w == g_host_win)
        return 1;
    /* Keep the Home host; leftover small GET_SURFACE is the ghost nav. */
    if (hosted && w == g_host_win && fly_mtlh_small_for_home(shm, w))
        return 1;
    hostCls = NSClassFromString(@"CALayerHost");
    cv = w.contentView;
    if (!hostCls || !cv) {
        logmsg("mtlh: host missing cls=%p cv=%p\n", hostCls, cv);
        return 0;
    }
    if (!cv.layer)
        cv.wantsLayer = YES;
    fly_remove_layer_hosts(cv);
    if (fly_mtlh_small_for_home(shm, w)) {
        logmsg("mtlh: skip small metal %ux%u on home %.0fx%.0f\n",
               shm->width, shm->height, w.frame.size.width, w.frame.size.height);
        return hosted && last_cid && w == g_host_win;
    }
    host = [hostCls layer];
    @try {
        [host setValue:@(shm->context_id) forKey:@"contextId"];
    } @catch (NSException *e) {
        logmsg("mtlh: CALayerHost set contextId EXC %s\n", e.description.UTF8String);
        return 0;
    }
    host.frame = cv.bounds;
    host.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    [cv.layer addSublayer:host];
    hosted = 1;
    last_cid = shm->context_id;
    g_host_win = w;
    logmsg("mtlh: hosted contextId=%u on win=%p %0.0fx%0.0f metal=%ux%u\n",
           last_cid, w, w.frame.size.width, w.frame.size.height,
           shm->width, shm->height);
    g_qt_hwnd = fly_wine_hwnd(w);
    fly_attach_cef_cocoa(w);
    return 1;
}

/* Connect-style: the Home HWND never setColorImage (R18 1600×976
 * updateLayer contents=0x0). Host follows the largest WineWindow. */
static void fly_bnet_connect_opaque(NSWindow *w)
{
    if (!w)
        return;
    @try {
        if ([w respondsToSelector:@selector(setUsePerPixelAlpha:)])
            [w setValue:@NO forKey:@"usePerPixelAlpha"];
        [w setOpaque:YES];
        [w setBackgroundColor:NSColor.windowBackgroundColor];
        if ([w respondsToSelector:@selector(checkTransparency)])
            [w performSelector:@selector(checkTransparency)];
        if (w.contentView && w.contentView.layer)
            w.contentView.layer.opaque = YES;
    } @catch (NSException *e) {
        logmsg("mtlh: opaque EXC %s\n", e.description.UTF8String);
    }
}

static NSWindow *fly_bnet_largest_win(void)
{
    Class wineWinCls = NSClassFromString(@"WineWindow");
    NSWindow *best = nil;
    CGFloat best_area = 0;

    if (!wineWinCls)
        return nil;
    for (NSWindow *w in fly_wine_nsapp_windows()) {
        CGFloat wf, hf, area;

        if (![w isKindOfClass:wineWinCls])
            continue;
        wf = w.frame.size.width;
        hf = w.frame.size.height;
        if (wf < 280.0 || hf < 280.0)
            continue;
        area = wf * hf;
        if (w.isKeyWindow || w.isMainWindow)
            area += 1.0;
        if (area > best_area) {
            best_area = area;
            best = w;
        }
    }
    return best;
}

/* EA 17:50: orderOut leftover 520×867 once library ≥900 is mapped.
 * Battle.net leftover is login-tall ~362×631/719 or HostedFlow ~392×391. */
static void fly_order_out_bnet_ghosts(NSWindow *keep)
{
    Class wineWinCls;
    if (!keep || !fly_bnet_home_win(keep))
        return;
    wineWinCls = NSClassFromString(@"WineWindow");
    if (!wineWinCls)
        return;
    for (NSWindow *win in fly_wine_nsapp_windows()) {
        CGFloat wf, hf;
        int leftover;

        if (win == keep || ![win isKindOfClass:wineWinCls])
            continue;
        wf = win.frame.size.width;
        hf = win.frame.size.height;
        leftover = (wf >= 280.0 && wf < 550.0 && hf >= 280.0 && hf < 780.0);
        if (!leftover)
            continue;
        if (!win.isVisible && wf < 80.0)
            continue;
        [win orderOut:nil];
        if (fly_cocoa_rate(&last_ghost_log_ms, 1000))
            logmsg("mtlh: ghost orderOut %p frame=%.0fx%.0f keep=%.0fx%.0f\n",
                   win, wf, hf, keep.frame.size.width, keep.frame.size.height);
    }
}

/* EA 13:55: 0×0 / orderOut HWND is invisible to Mission Control.
 * R20 orderOut login on the 1434 splash — bring a real window back. */
static void fly_ensure_bnet_window_visible(void)
{
    NSScreen *sc;
    NSRect vis, f, nf;
    NSWindow *w;
    int tiny, off, hidden;
    CGFloat rw, rh;

    if (!fly_is_bnet_parent() || force_cocoa_fast)
        return;
    w = nil;
    for (NSWindow *cand in fly_wine_nsapp_windows()) {
        if (fly_bnet_home_win(cand)) {
            w = cand;
            break;
        }
    }
    if (!w)
        w = fly_bnet_largest_win();
    if (!w)
        return;
    sc = w.screen ?: [NSScreen mainScreen];
    vis = sc ? sc.visibleFrame : NSMakeRect(80, 80, 1280, 800);
    f = w.frame;
    tiny = (f.size.width < 80.0 || f.size.height < 80.0);
    off = (NSMaxX(f) < vis.origin.x + 16 || NSMaxY(f) < vis.origin.y + 16 ||
           f.origin.x > NSMaxX(vis) - 16 || f.origin.y > NSMaxY(vis) - 16);
    hidden = !w.isVisible;
    if (tiny) {
        rw = fly_bnet_home_win(w) ? 1600.0 : 362.0;
        rh = fly_bnet_home_win(w) ? 976.0 : 719.0;
        nf = NSMakeRect(vis.origin.x + (vis.size.width - rw) * 0.5,
                        vis.origin.y + (vis.size.height - rh) * 0.5,
                        rw, rh);
        [w setFrame:nf display:YES];
    } else if (off) {
        nf = f;
        nf.origin.x = vis.origin.x + 80;
        nf.origin.y = vis.origin.y + 80;
        [w setFrame:nf display:YES];
    }
    if (tiny || off || hidden) {
        [w setIsVisible:YES];
        [w orderFrontRegardless];
        [w makeKeyAndOrderFront:nil];
        if (fly_cocoa_rate(&last_cocoa_log_ms, 800))
            logmsg("mtlh: restore visible win=%p tiny=%d off=%d hid=%d %.0fx%.0f\n",
                   w, tiny, off, hidden, w.frame.size.width, w.frame.size.height);
    }
}

static void fly_host_follow_largest(void)
{
    NSWindow *w;
    int hosted;

    if (!fly_is_bnet_parent() || force_cocoa_fast)
        return;
    fly_ensure_bnet_window_visible();
    w = fly_bnet_largest_win();
    if (!w)
        return;
    hosted = fly_host_gpu_metal(w);
    if (fly_bnet_home_win(w))
        fly_bnet_connect_opaque(w);
    /* R20: never orderOut login/splash (1434 Agent/splash is not Home). */
    if (hosted && fly_cocoa_rate(&last_cocoa_log_ms, 800))
        logmsg("mtlh: follow hosted=1 win=%p %.0fx%.0f hwnd=%p\n",
               w, w.frame.size.width, w.frame.size.height, fly_wine_hwnd(w));
}

static void fly_show_metal_views(NSWindow *w)
{
    Class metalCls;
    NSView *cv;
    NSMutableArray<NSView *> *stack;
    int shown = 0;
    if (!w)
        return;
    metalCls = NSClassFromString(@"WineMetalView");
    if (!metalCls)
        return;
    cv = w.contentView;
    if (!cv)
        return;
    stack = [NSMutableArray arrayWithObject:cv];
    for (NSUInteger i = 0; i < stack.count; i++) {
        NSView *v = stack[i];
        if (v.subviews.count)
            [stack addObjectsFromArray:v.subviews];
        if ([v isKindOfClass:metalCls] && v.hidden) {
            v.hidden = NO;
            shown++;
        }
    }
    cocoa_metal_hidden = 0;
    if (shown)
        logmsg("cocoa-fast unhid %d WineMetalView(s) win=%p\n", shown, w);
}

static void fly_hide_metal_views(NSWindow *w, unsigned nz)
{
    Class metalCls;
    NSView *cv;
    NSMutableArray<NSView *> *stack;
    int hid = 0;
    if (!w || cocoa_never_hide_metal)
        return;
    /* Never hide the only composited layer until FLY4 has pixels AND a frame. */
    if (nz < 64 || w.frame.size.width < 80.0 || w.frame.size.height < 80.0)
        return;
    metalCls = NSClassFromString(@"WineMetalView");
    if (!metalCls)
        return;
    cv = w.contentView;
    if (!cv)
        return;
    stack = [NSMutableArray arrayWithObject:cv];
    for (NSUInteger i = 0; i < stack.count; i++) {
        NSView *v = stack[i];
        if (v.subviews.count)
            [stack addObjectsFromArray:v.subviews];
        if ([v isKindOfClass:metalCls] && !v.hidden) {
            v.hidden = YES;
            hid++;
        }
    }
    if (hid) {
        cocoa_metal_hidden = 1;
        if (fly_cocoa_rate(&last_cocoa_log_ms, 400))
            logmsg("cocoa-fast hid %d WineMetalView(s) win=%p nz=%u frame=%.0fx%.0f\n",
                   hid, w, nz, w.frame.size.width, w.frame.size.height);
        if (w.frame.size.width < 80.0 || w.frame.size.height < 80.0) {
            fly_show_metal_views(w);
            cocoa_collapse_hits++;
            logmsg("cocoa-fast hide collapsed window hits=%u — showing Metal\n",
                   cocoa_collapse_hits);
            if (cocoa_collapse_hits >= 2)
                cocoa_never_hide_metal = 1;
        }
    }
}

/* Map the 0×0 / off-screen “EA” ghost back onto the visible display.
 * After login, do NOT restore the leftover 520×867 HWND and do NOT
 * orderFront/deminiaturize a mapped library — that was the 17:41
 * undismissable strip (FLY4 1536×827 squeezed into 520×867, sitting at Y=55
 * above the 1536×781 library). */
static void fly_ensure_ea_window_visible(NSWindow *w)
{
    NSScreen *sc;
    NSRect vis, f, nf;
    int tiny, off;
    NSWindow *primary;
    if (!w || cocoa_user_closed)
        return;
    if (w.frame.size.width >= 900.0 && fly_is_ea_title(w)) {
        cocoa_library_mode = 1;
        cocoa_last_fw = (int)w.frame.size.width;
        cocoa_last_fh = (int)w.frame.size.height;
    }
    primary = fly_primary_ea_window();
    if (cocoa_library_mode) {
        if (primary)
            fly_order_out_ea_ghosts(primary);
        if (w != primary) {
            if (fly_window_login_sized(w) && (w.isVisible || w.frame.size.width >= 80.0))
                [w orderOut:nil];
            return;
        }
        fly_ensure_ea_chrome(w);
        tiny = (w.frame.size.width < 80.0 || w.frame.size.height < 80.0);
        if (!tiny)
            return;
        /* Library collapsed to 0×0 (13:55 hide storm) — restore library size. */
    } else if (primary && w != primary) {
        return;
    }
    sc = w.screen ?: [NSScreen mainScreen];
    vis = sc ? sc.visibleFrame : NSMakeRect(80, 80, 1280, 800);
    f = w.frame;
    tiny = (f.size.width < 80.0 || f.size.height < 80.0);
    off = (NSMaxX(f) < vis.origin.x + 16 || NSMaxY(f) < vis.origin.y + 16 ||
           f.origin.x > NSMaxX(vis) - 16 || f.origin.y > NSMaxY(vis) - 16);
    if (tiny || off) {
        CGFloat rw = cocoa_library_mode ? (CGFloat)cocoa_last_fw : 520.0;
        CGFloat rh = cocoa_library_mode ? (CGFloat)cocoa_last_fh : 867.0;
        if (rw < 80.0)
            rw = 520.0;
        if (rh < 80.0)
            rh = 867.0;
        nf = NSMakeRect(vis.origin.x + (vis.size.width - rw) * 0.5,
                        vis.origin.y + (vis.size.height - rh) * 0.5,
                        rw, rh);
        if (nf.origin.x < vis.origin.x)
            nf.origin.x = vis.origin.x + 40;
        if (nf.origin.y < vis.origin.y)
            nf.origin.y = vis.origin.y + 40;
        [w setFrame:nf display:YES];
        logmsg("cocoa-fast restore frame tiny=%d off=%d was=%.0fx%.0f@%.0f,%.0f to=%.0fx%.0f lib=%d\n",
               tiny, off, f.size.width, f.size.height, f.origin.x, f.origin.y,
               rw, rh, cocoa_library_mode);
        [w setIsVisible:YES];
        [w orderFrontRegardless];
        [w makeKeyAndOrderFront:nil];
    }
    fly_ensure_ea_chrome(w);
}

static void fly_apply_shm4_to_view(NSView *view, CGImageRef img, int w, int h, unsigned nz,
                                   const char *why)
{
    NSWindow *win;
    int from_layer;
    if (!view || !img)
        return;
    win = view.window;
    if (cocoa_user_closed || !fly_window_is_primary_ea(win))
        return;
    fly_ensure_ea_window_visible(win);
    /* updateLayer → setNeedsDisplay is the 13:47 0×0 / 100% CPU storm. */
    from_layer = (why && strcmp(why, "updateLayer") == 0);
    if (!from_layer && !fly_cocoa_rate(&last_cocoa_apply_ms, 200))
        return;
    in_cocoa_fast = 1;
    @try {
        if ([win respondsToSelector:@selector(setUsePerPixelAlpha:)])
            [win setValue:@NO forKey:@"usePerPixelAlpha"];
        if ([view respondsToSelector:@selector(setShapeImage:)])
            ((void (*)(id, SEL, CGImageRef))objc_msgSend)(view, @selector(setShapeImage:), NULL);
        [win setOpaque:YES];
        if (view.layer) {
            view.layer.opaque = YES;
            view.layer.contents = (__bridge id)img;
            view.layer.contentsGravity = kCAGravityResize;
        }
        if ([view respondsToSelector:@selector(setColorImage:)])
            ((void (*)(id, SEL, CGImageRef))objc_msgSend)(view, @selector(fly_setColorImage:), img);
        if ([win respondsToSelector:@selector(checkTransparency)])
            [win performSelector:@selector(checkTransparency)];
        fly_hide_metal_views(win, nz);
        fly_ensure_ea_window_visible(win);
        if (nz >= 64)
            last_cocoa_good_ms = inject_now_ms();
        if (fly_cocoa_rate(&last_cocoa_log_ms, 400))
            logmsg("cocoa-fast %s view=%p %dx%d nz=%u bounds=%.0fx%.0f frame=%.0fx%.0f vis=%d\n",
                   why, view, w, h, nz, view.bounds.size.width, view.bounds.size.height,
                   win.frame.size.width, win.frame.size.height, (int)win.isVisible);
    } @catch (NSException *e) {
        logmsg("cocoa-fast EXC %s\n", e.description.UTF8String);
        fly_show_metal_views(win);
        fly_ensure_ea_window_visible(win);
    }
    in_cocoa_fast = 0;
}

static int fly_is_upc_process(void)
{
    static int stable_hits;
    int cur = 0;
    int argc, i;
    char **argv;
    int has_upc = 0, has_start = 0, has_webcore = 0;

    /* Prefer unix argv (same as epi bridge) — NSProcessInfo often lacks PE path at +load. */
    argc = *_NSGetArgc();
    argv = *_NSGetArgv();
    if (argv) {
        for (i = 0; i < argc; i++) {
            const char *a = argv[i];
            const char *base;
            if (!a) continue;
            if (strcasestr(a, "UplayWebCore") || strcasestr(a, "EACefSubProcess"))
                has_webcore = 1;
            if (strcasestr(a, "start.exe"))
                has_start = 1;
            base = strrchr(a, '\\');
            if (!base) base = strrchr(a, '/');
            base = base ? base + 1 : a;
            if (strcasecmp(base, "upc.exe") == 0 || strcasecmp(base, "EADesktop.exe") == 0)
                has_upc = 1;
            if (strcasecmp(base, "start.exe") == 0)
                has_start = 1;
        }
    }
    if (!has_webcore && !has_start && has_upc)
        cur = 1;

    if (is_upc_process < 0 || (is_upc_process == 0 && cur == 1) || stable_hits < 3) {
        is_upc_process = cur;
        if (cur)
            stable_hits++;
    }
    return is_upc_process > 0;
}

static void resolve_parent_gdi(void)
{
    uint8_t *wsf;
    if (parent_gdi_resolved)
        return;
    parent_gdi_resolved = 1;
    p_GetDCEx = (NtUserGetDCEx_fn)dlsym(RTLD_DEFAULT, "NtUserGetDCEx");
    if (!p_GetDCEx) p_GetDCEx = (NtUserGetDCEx_fn)dlsym(RTLD_DEFAULT, "_NtUserGetDCEx");
    p_ReleaseDC = (NtUserReleaseDC_fn)dlsym(RTLD_DEFAULT, "NtUserReleaseDC");
    if (!p_ReleaseDC) p_ReleaseDC = (NtUserReleaseDC_fn)dlsym(RTLD_DEFAULT, "_NtUserReleaseDC");
    p_SetDIBits = (NtGdiSetDIBitsToDeviceInternal_fn)dlsym(RTLD_DEFAULT, "NtGdiSetDIBitsToDeviceInternal");
    if (!p_SetDIBits)
        p_SetDIBits = (NtGdiSetDIBitsToDeviceInternal_fn)dlsym(RTLD_DEFAULT, "_NtGdiSetDIBitsToDeviceInternal");
    wsf = (uint8_t *)dlsym(RTLD_DEFAULT, "window_surface_flush");
    if (!wsf) wsf = (uint8_t *)dlsym(RTLD_DEFAULT, "_window_surface_flush");
    if (wsf)
        p_flush_window_surfaces = (flush_window_surfaces_fn)(wsf - 0x14e50 + 0x175e0);
    logmsg("parent_gdi getdcex=%d setdib=%d flush=%p\n",
           p_GetDCEx ? 1 : 0, p_SetDIBits ? 1 : 0, (void *)p_flush_window_surfaces);
}

/* Cross-process present: GPU wrote pixels+hwnd; upc applies SetDIBits+flush locally
 * (Wine shm parent path equivalent). */
static int fly_parent_present_bits(void *bits, int w, int h, uint64_t hwnd64)
{
    HWND hwnd;
    HDC hdc;
    BITMAPINFO bmi;
    INT dib_rc;
    int flushed = 0;

    if (!force_parent_present || !bits || w < 8 || h < 8 || !hwnd64)
        return 0;
    resolve_parent_gdi();
    if (!p_GetDCEx || !p_SetDIBits || !p_ReleaseDC)
        return -1;

    hwnd = (HWND)(uintptr_t)hwnd64;
    hdc = p_GetDCEx(hwnd, 0, DCX_CLIPSIBLINGS);
    if (!hdc) {
        parent_present_fail++;
        logmsg("PARENT_PRESENT GetDCEx fail hwnd=%p\n", (void *)hwnd);
        return -2;
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
    p_ReleaseDC(hwnd, hdc);
    if (p_flush_window_surfaces) {
        p_flush_window_surfaces(1);
        flushed = 1;
    }
    if (dib_rc > 0) {
        parent_present_ok++;
        logmsg("PARENT_PRESENT ok hwnd=%p dib=%d flush=%d %dx%d ok=%u fail=%u\n",
               (void *)hwnd, dib_rc, flushed, w, h, parent_present_ok, parent_present_fail);
        return 1;
    }
    parent_present_fail++;
    logmsg("PARENT_PRESENT SetDIBits fail hwnd=%p dib=%d %dx%d\n", (void *)hwnd, dib_rc, w, h);
    return -3;
}

static CGImageRef fly_solid_cgimage(size_t w, size_t h, uint32_t bgra)
{
    size_t bpr = w * 4;
    size_t nbytes = bpr * h;
    void *buf = malloc(nbytes);
    if (!buf) return NULL;
    uint32_t *p = (uint32_t *)buf;
    size_t n = w * h;
    for (size_t i = 0; i < n; i++) p[i] = bgra;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, bpr, cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
    if (ctx) CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    free(buf);
    return img;
}

static void ensure_proc_label(void)
{
    if (proc_label[0]) return;
    @autoreleasepool {
        NSProcessInfo *pi = NSProcessInfo.processInfo;
        NSString *name = pi.processName ?: @"?";
        NSString *arg0 = pi.arguments.count ? pi.arguments[0] : @"?";
        const char *leaf = strrchr(arg0.UTF8String, '/');
        leaf = leaf ? leaf + 1 : arg0.UTF8String;
        snprintf(proc_label, sizeof(proc_label), "pid=%d name=%s arg0=%s",
                 (int)getpid(), name.UTF8String, leaf);
    }
}

static void logmsg(const char *fmt, ...)
{
    va_list ap;
    pthread_mutex_lock(&logmu);
    if (!logfp) {
        const char *p = getenv("PRESENT_FORCE_LOG");
        logfp = fopen(p && *p ? p : "/tmp/present-force-inject.log", "a");
        if (logfp) setvbuf(logfp, NULL, _IONBF, 0);
    }
    if (logfp) {
        ensure_proc_label();
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        fprintf(logfp, "%ld.%03ld [%s] ", (long)ts.tv_sec, ts.tv_nsec / 1000000L, proc_label);
        va_start(ap, fmt);
        vfprintf(logfp, fmt, ap);
        va_end(ap);
    }
    pthread_mutex_unlock(&logmu);
}

static void swizzle(Class cls, SEL orig, SEL repl)
{
    Method m1 = class_getInstanceMethod(cls, orig);
    Method m2 = class_getInstanceMethod(cls, repl);
    if (!m1 || !m2) {
        logmsg("swizzle miss %s %s (m1=%p m2=%p)\n",
               class_getName(cls), sel_getName(orig), m1, m2);
        return;
    }
    method_exchangeImplementations(m1, m2);
    logmsg("swizzled %s %s\n", class_getName(cls), sel_getName(orig));
}

/* WineWindow often does not override NSWindow setStyleMask:/performClose:.
 * Adding the method on WineWindow avoids swizzling NSWindow globally. */
static void swizzle_or_add(Class cls, SEL orig, SEL repl)
{
    Method m1 = class_getInstanceMethod(cls, orig);
    Method m2 = class_getInstanceMethod(cls, repl);
    if (!m1 || !m2) {
        logmsg("swizzle_or_add miss %s %s (m1=%p m2=%p)\n",
               class_getName(cls), sel_getName(orig), m1, m2);
        return;
    }
    if (class_addMethod(cls, orig, method_getImplementation(m2), method_getTypeEncoding(m2))) {
        class_replaceMethod(cls, repl, method_getImplementation(m1), method_getTypeEncoding(m1));
        logmsg("swizzle_or_add added %s %s\n", class_getName(cls), sel_getName(orig));
    } else {
        method_exchangeImplementations(m1, m2);
        logmsg("swizzle_or_add exchanged %s %s\n", class_getName(cls), sel_getName(orig));
    }
}

@interface NSObject (FlyPresentForce)
- (void)fly_setColorImage:(CGImageRef)image;
- (void)fly_setShapeImage:(CGImageRef)image;
- (void)fly_setUsePerPixelAlpha:(BOOL)v;
- (void)fly_updateLayer;
- (void)fly_setStyleMask:(NSUInteger)mask;
- (void)fly_performClose:(id)sender;
- (void)fly_mouseDown:(NSEvent *)ev;
- (void)fly_mouseUp:(NSEvent *)ev;
- (void)fly_rightMouseDown:(NSEvent *)ev;
- (void)fly_rightMouseUp:(NSEvent *)ev;
- (void)fly_mouseDragged:(NSEvent *)ev;
- (void)fly_scrollWheel:(NSEvent *)ev;
- (void)fly_keyDown:(NSEvent *)ev;
- (void)fly_keyUp:(NSEvent *)ev;
@end

@implementation NSObject (FlyPresentForce)

static unsigned fly_cgimage_nz(CGImageRef image, unsigned *nonbg_out, uint32_t *sample_out)
{
    size_t iw, ih, row, x, y;
    CGColorSpaceRef cs;
    CGContextRef ctx;
    uint32_t *buf;
    unsigned nz = 0, nonbg = 0;
    uint32_t bg = 0x000d0d0du; /* Connect dark chrome */

    if (sample_out) *sample_out = 0;
    if (nonbg_out) *nonbg_out = 0;
    if (!image) return 0;
    iw = CGImageGetWidth(image);
    ih = CGImageGetHeight(image);
    if (iw < 1 || ih < 1 || iw > 4096 || ih > 4096) return 0;
    buf = calloc(iw * ih, 4);
    if (!buf) return 0;
    cs = CGColorSpaceCreateDeviceRGB();
    ctx = CGBitmapContextCreate(buf, iw, ih, 8, iw * 4, cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    if (ctx) {
        CGContextDrawImage(ctx, CGRectMake(0, 0, iw, ih), image);
        CGContextRelease(ctx);
    }
    CGColorSpaceRelease(cs);
    /* Sample a grid — full scan is fine at ≤1536x1024 occasionally. */
    for (y = 0; y < ih; y += (ih > 200 ? 4 : 1)) {
        for (x = 0; x < iw; x += (iw > 200 ? 4 : 1)) {
            uint32_t px = buf[y * iw + x] & 0x00ffffffu;
            if (px) nz++;
            if (px && px != bg) nonbg++;
        }
    }
    /* Center pixel as quick visual cue */
    if (sample_out)
        *sample_out = buf[(ih / 2) * iw + (iw / 2)];
    free(buf);
    if (nonbg_out) *nonbg_out = nonbg;
    return nz;
}

- (void)fly_setColorImage:(CGImageRef)image
{
    size_t iw = image ? CGImageGetWidth(image) : 0;
    size_t ih = image ? CGImageGetHeight(image) : 0;
    CGImageAlphaInfo ai = image ? CGImageGetAlphaInfo(image) : (CGImageAlphaInfo)0;
    NSView *view = (NSView *)self;
    NSWindow *w = ([self isKindOfClass:[NSView class]]) ? view.window : nil;
    void *hwnd = NULL;
    int key = 0, mainw = 0, visible = 0;
    CGFloat wf = 0, hf = 0;

    if (w) {
        Class wineWinCls = NSClassFromString(@"WineWindow");
        wf = w.frame.size.width;
        hf = w.frame.size.height;
        key = w.isKeyWindow;
        mainw = w.isMainWindow;
        visible = w.isVisible;
        if (wineWinCls && [w isKindOfClass:wineWinCls]) {
            Ivar ihw = class_getInstanceVariable(object_getClass(w), "hwnd");
            if (!ihw) ihw = class_getInstanceVariable(wineWinCls, "hwnd");
            if (ihw) hwnd = *(void **)((char *)(__bridge void *)w + ivar_getOffset(ihw));
        }
    }

    /* Leftover login HWND after library maps — hide immediately (don't wait for poll). */
    if (force_cocoa_fast && cocoa_library_mode && fly_window_login_sized(w) &&
        !fly_window_is_primary_ea(w)) {
        [w orderOut:nil];
    }

    /* EA login is 520×867; Wine then setColorImage's a 640×896 DXVK frame (black).
     * Replace with FLY4 if we have real pixels — Connect fallback, EA-gated.
     * Only the primary “EA” HWND — leftover login 520×867 must not get the
     * library FLY4 (17:41 distorted nav strip). */
    if (force_cocoa_fast && !in_cocoa_fast && fly_is_upc_process() &&
        !cocoa_user_closed && fly_window_is_primary_ea(w)) {
        unsigned nz = 0;
        int fw = 0, fh = 0;
        CGImageRef fast = fly_shm4_cgimage(&nz, &fw, &fh);
        if (fast) {
            static long long last_sub_ms;
            long long now = inject_now_ms();
            fly_ensure_ea_window_visible(w);
            fly_hide_metal_views(w, nz);
            fly_ensure_ea_window_visible(w);
            if (!last_sub_ms || now - last_sub_ms >= 400) {
                last_sub_ms = now;
                logmsg("cocoa-fast replace setColorImage wine=%zux%zu with FLY4 %dx%d nz=%u frame=%.0fx%.0f\n",
                       iw, ih, fw, fh, nz, w ? w.frame.size.width : 0, w ? w.frame.size.height : 0);
            }
            [self fly_setColorImage:fast];
            if (view.layer) {
                view.layer.contents = (__bridge id)fast;
                view.layer.contentsGravity = kCAGravityResize;
            }
            if (nz >= 64)
                last_cocoa_good_ms = now;
            CGImageRelease(fast);
            return;
        }
        if (fast)
            CGImageRelease(fast);
    }

    /* Login-ish presents: sample pixel richness (proves flush bits vs empty CGImage). */
    if (image && ((iw >= 400 && ih >= 400) || (wf >= 400 && hf >= 400))) {
        static long long last_sci_sample_ms;
        long long now = inject_now_ms();
        unsigned nz = 0, nonbg = 0;
        uint32_t sample = 0;
        if (!last_sci_sample_ms || now - last_sci_sample_ms >= 400) {
            last_sci_sample_ms = now;
            nz = fly_cgimage_nz(image, &nonbg, &sample);
            logmsg("setColorImage RICH self=%p img=%zux%zu alpha=%u nz=%u nonbg=%u center=0x%08x win=%p hwnd=%p frame=%.0fx%.0f key=%d main=%d vis=%d opaque=%d contents=%p\n",
                   self, iw, ih, (unsigned)ai, nz, nonbg, sample, w, hwnd, wf, hf,
                   key, mainw, visible, w ? (int)w.isOpaque : -1,
                   (view.layer ? view.layer.contents : nil));
        } else {
            logmsg("setColorImage: self=%p img=%zux%zu alphaInfo=%u hwnd=%p frame=%.0fx%.0f key=%d\n",
                   self, iw, ih, (unsigned)ai, hwnd, wf, hf, key);
        }
    } else if (!force_cocoa_fast || fly_cocoa_rate(&last_cocoa_log_ms, 400)) {
        logmsg("setColorImage: self=%p img=%zux%zu alphaInfo=%u\n", self, iw, ih, (unsigned)ai);
    }
    /* Login + HostedFlow + Home: CALayerHost GPU Metal onto the HWND
     * that is painting now. R17 skipped GDI after login host without
     * attaching to the new window (contents=0x0). First R18 Play blit
     * leftover FLY4 392×719 onto 392×391 (black). Same composite as
     * login; FLY4 only when shm size matches this frame. */
    if (!force_cocoa_fast && w && fly_is_bnet_parent() &&
        fly_bnet_present_win(w, iw, ih)) {
        int nmetal = fly_metal_present_count(w);
        int hosted = 0;
        unsigned nz = 0;
        int fw = 0, fh = 0;
        CGImageRef fast = nil;

        if (hwnd)
            g_qt_hwnd = hwnd;
        hosted = fly_host_gpu_metal(w);
        if (fly_cocoa_rate(&last_cocoa_log_ms, 400))
            logmsg("setColorImage metal=%d hosted=%d img=%zux%zu frame=%.0fx%.0f hwnd=%p\n",
                   nmetal, hosted, iw, ih, wf, hf, hwnd);
        if (nmetal > 0 || hosted) {
            fly_show_metal_views(w);
            fly_raise_metal_views(w);
            if (view.layer)
                view.layer.contents = nil;
            return;
        }
        fast = fly_shm4_cgimage(&nz, &fw, &fh);
        if (fast && abs(fw - (int)wf) <= 80 && abs(fh - (int)hf) <= 80) {
            if (fly_cocoa_rate(&last_cocoa_log_ms, 400))
                logmsg("mtlh: postlogin FLY4 %dx%d nz=%u frame=%.0fx%.0f hwnd=%p\n",
                       fw, fh, nz, wf, hf, hwnd);
            [self fly_setColorImage:fast];
            if (view.layer) {
                view.layer.contents = (__bridge id)fast;
                view.layer.contentsGravity = kCAGravityResize;
            }
            CGImageRelease(fast);
            if ([w respondsToSelector:@selector(setUsePerPixelAlpha:)])
                [w setValue:@NO forKey:@"usePerPixelAlpha"];
            [w setOpaque:YES];
            return;
        }
        if (fast)
            CGImageRelease(fast);
        if (fly_cocoa_rate(&last_cocoa_log_ms, 400))
            logmsg("mtlh: postlogin GDI img=%zux%zu frame=%.0fx%.0f hwnd=%p\n",
                   iw, ih, wf, hf, hwnd);
        [self fly_setColorImage:image];
        if ([w respondsToSelector:@selector(setUsePerPixelAlpha:)])
            [w setValue:@NO forKey:@"usePerPixelAlpha"];
        [w setOpaque:YES];
        if ([w respondsToSelector:@selector(checkTransparency)])
            [w performSelector:@selector(checkTransparency)];
        return;
    }
    [self fly_setColorImage:image]; /* exchanged → original */
    if (force_opaque) {
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                if ([w respondsToSelector:@selector(setUsePerPixelAlpha:)])
                    [w setValue:@NO forKey:@"usePerPixelAlpha"];
                if ([self respondsToSelector:@selector(setShapeImage:)])
                    [self performSelector:@selector(setShapeImage:) withObject:nil];
                if ([w respondsToSelector:@selector(checkTransparency)])
                    [w performSelector:@selector(checkTransparency)];
                [w setOpaque:YES];
                [w setBackgroundColor:NSColor.windowBackgroundColor];
                if (view.layer) view.layer.opaque = YES;
                [view setNeedsDisplay:YES];
                logmsg("force after setColorImage win=%p opaque=%d contents=%p %.0fx%.0f\n",
                       w, (int)w.isOpaque, view.layer.contents,
                       w.frame.size.width, w.frame.size.height);
            } @catch (NSException *e) {
                logmsg("force EXC %s\n", e.description.UTF8String);
            }
        });
    }
}

- (void)fly_setShapeImage:(CGImageRef)image
{
    size_t iw = image ? CGImageGetWidth(image) : 0;
    size_t ih = image ? CGImageGetHeight(image) : 0;
    if (!force_cocoa_fast || fly_cocoa_rate(&last_cocoa_log_ms, 400))
        logmsg("setShapeImage: self=%p img=%zux%zu%s\n", self, iw, ih, image ? "" : " (NULL)");
    if (force_opaque) {
        logmsg("setShapeImage DROPPED\n");
        [self fly_setShapeImage:NULL];
        return;
    }
    [self fly_setShapeImage:image];
}

- (void)fly_setUsePerPixelAlpha:(BOOL)v
{
    if (!force_cocoa_fast || fly_cocoa_rate(&last_cocoa_log_ms, 400))
        logmsg("setUsePerPixelAlpha: self=%p v=%d%s\n", self, (int)v, force_opaque ? " ->0" : "");
    [self fly_setUsePerPixelAlpha:force_opaque ? NO : v];
}

- (void)fly_updateLayer
{
    NSView *view = (NSView *)self;
    id contents_before = view.layer.contents;
    CGFloat bw = view.layer.bounds.size.width;
    CGFloat bh = view.layer.bounds.size.height;
    [self fly_updateLayer];
    id contents_after = view.layer.contents;
    CGFloat scale = view.layer.contentsScale;
    if (!force_cocoa_fast || fly_cocoa_rate(&last_cocoa_log_ms, 400))
        logmsg("updateLayer self=%p scale=%.2f contents %p -> %p bounds=%.0fx%.0f\n",
               self, scale, contents_before, contents_after, bw, bh);
    /* Do not apply FLY4 from updateLayer — that setNeedsDisplay loop hid
     * WineMetalView millions of times and collapsed the EA window to 0×0. */
    if (force_surface_map && bw >= 400.0 && bh >= 400.0) {
        NSWindow *w = view.window;
        void *hwnd = NULL;
        void *surface = NULL;
        int ppa = -1;
        Class wineWinCls = NSClassFromString(@"WineWindow");
        if (wineWinCls && w && [w isKindOfClass:wineWinCls]) {
            @try { hwnd = [[w valueForKey:@"hwnd"] pointerValue]; } @catch (NSException *e) {}
            @try { surface = [[w valueForKey:@"surface"] pointerValue]; } @catch (NSException *e) {}
            @try { ppa = [[w valueForKey:@"usePerPixelAlpha"] boolValue] ? 1 : 0; } @catch (NSException *e) {}
        }
        logmsg("SURFACE_MAP updateLayer view=%p bounds=%.0fx%.0f contents=%p win=%p hwnd=%p surface=%p ppa=%d\n",
               self, bw, bh, contents_after, w, hwnd, surface, ppa);
        if (contents_after == nil && bw >= 1400.0)
            fly_surface_map_dump("login-nil");
    }

    /* Cocoa half of macdrv layered→non-layered clear: splash ULW leaves
     * usePerPixelAlpha set; login StretchBlt surface never setColorImage, so
     * updateLayer keeps nil contents. Clear per-pixel / shape on login-sized
     * empty presents so a later setColorImage can stick opaque. */
    /* Also catch hub/resized login (~1432×668) with nil contents — strict 1400×900
     * missed the visible transparent frame while poll painted a different view. */
    if (bw >= 400.0 && bh >= 400.0 && contents_after == nil) {
        NSWindow *w = view.window;
        /* Big Home HWND: no setColorImage. Host + Connect opaque here. */
        if (!force_cocoa_fast && fly_is_bnet_parent() &&
            bw >= 800.0 && bh >= 500.0) {
            fly_host_follow_largest();
        }
        if (force_login_bridge && bridge_bgra_path[0]) {
            struct stat st;
            if (stat(bridge_bgra_path, &st) == 0) {
                long mtime_ns = (long)st.st_mtimespec.tv_sec * 1000000000L + (long)st.st_mtimespec.tv_nsec;
                if (mtime_ns != last_bridge_mtime_ns) {
                    unsigned nz = 0;
                    int iw = 0, ih = 0;
                    CGImageRef bridged = fly_bgra_file_cgimage(bridge_bgra_path, &nz, &iw, &ih);
                    char json[256];
                    snprintf(json, sizeof(json),
                             "{\"nz\":%u,\"w\":%d,\"h\":%d,\"pathExists\":1,\"img\":%s}",
                             nz, iw, ih, bridged ? "true" : "false");
                    agent_log("E", "bridge bgra read", json);
                    logmsg("login-bridge read nz=%u %dx%d img=%p\n", nz, iw, ih, bridged);
                    if (bridged && nz > 0) {
                        last_bridge_mtime_ns = mtime_ns;
                        last_bridge_nz = nz;
                        login_bridge_done = 1;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            @try {
                                if ([w respondsToSelector:@selector(setUsePerPixelAlpha:)])
                                    [w setValue:@NO forKey:@"usePerPixelAlpha"];
                                if ([self respondsToSelector:@selector(setShapeImage:)])
                                    [self performSelector:@selector(setShapeImage:) withObject:nil];
                                [w setOpaque:YES];
                                if (view.layer) view.layer.opaque = YES;
                                if ([self respondsToSelector:@selector(setColorImage:)]) {
                                    [self fly_setColorImage:bridged];
                                    if (view.layer) {
                                        view.layer.contents = (__bridge id)bridged;
                                        view.layer.contentsGravity = kCAGravityResize;
                                    }
                                    logmsg("login-bridge setColorImage %dx%d nz=%u\n", iw, ih, nz);
                                    agent_log("R3", "bridge setColorImage", "{\"ok\":1}");
                                }
                                if ([w respondsToSelector:@selector(checkTransparency)])
                                    [w performSelector:@selector(checkTransparency)];
                                [view setNeedsDisplay:YES];
                                [view displayIfNeeded];
                            } @catch (NSException *e) {
                                logmsg("login-bridge EXC %s\n", e.description.UTF8String);
                            }
                            CGImageRelease(bridged);
                        });
                        return;
                    }
                    if (bridged) CGImageRelease(bridged);
                }
            } else if (!login_bridge_done) {
                agent_log("E", "bridge bgra missing", "{\"pathExists\":0}");
            }
        }
        if (force_login_fill && !login_fill_done) {
            login_fill_done = 1;
            size_t iw = (size_t)bw;
            size_t ih = (size_t)bh;
            CGImageRef solid = fly_solid_cgimage(iw, ih, 0xFFFF0080); /* opaque hot pink BGRA */
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    if ([w respondsToSelector:@selector(setUsePerPixelAlpha:)])
                        [w setValue:@NO forKey:@"usePerPixelAlpha"];
                    if ([self respondsToSelector:@selector(setShapeImage:)])
                        [self performSelector:@selector(setShapeImage:) withObject:nil];
                    [w setOpaque:YES];
                    if (view.layer) view.layer.opaque = YES;
                    if (solid && [self respondsToSelector:@selector(setColorImage:)]) {
                        /* Call real setColorImage via exchanged name */
                        [self fly_setColorImage:solid];
                        logmsg("login-fill setColorImage %zux%zu solid=%p\n", iw, ih, solid);
                    } else if (solid && view.layer) {
                        view.layer.contents = (__bridge id)solid;
                        logmsg("login-fill layer.contents %zux%zu\n", iw, ih);
                    }
                    if ([w respondsToSelector:@selector(checkTransparency)])
                        [w performSelector:@selector(checkTransparency)];
                    [view setNeedsDisplay:YES];
                    logmsg("login-fill done win=%p opaque=%d contents=%p\n",
                           w, (int)w.isOpaque, view.layer.contents);
                } @catch (NSException *e) {
                    logmsg("login-fill EXC %s\n", e.description.UTF8String);
                }
                if (solid) CGImageRelease(solid);
            });
        } else if (force_login_sync && !login_sync_done) {
            login_sync_done = 1;
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    if ([w respondsToSelector:@selector(setUsePerPixelAlpha:)])
                        [w setValue:@NO forKey:@"usePerPixelAlpha"];
                    if ([self respondsToSelector:@selector(setShapeImage:)])
                        [self performSelector:@selector(setShapeImage:) withObject:nil];
                    if ([w respondsToSelector:@selector(checkTransparency)])
                        [w performSelector:@selector(checkTransparency)];
                    [w setOpaque:YES];
                    if (view.layer) view.layer.opaque = YES;
                    [view setNeedsDisplay:YES];
                    [self fly_updateLayer];
                    logmsg("login-sync done win=%p opaque=%d contents=%p\n",
                           w, (int)w.isOpaque, view.layer.contents);
                } @catch (NSException *e) {
                    logmsg("login-sync EXC %s\n", e.description.UTF8String);
                }
            });
        } else if (force_opaque) {
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    if ([w respondsToSelector:@selector(setUsePerPixelAlpha:)])
                        [w setValue:@NO forKey:@"usePerPixelAlpha"];
                    if ([self respondsToSelector:@selector(setShapeImage:)])
                        [self performSelector:@selector(setShapeImage:) withObject:nil];
                    if ([w respondsToSelector:@selector(checkTransparency)])
                        [w performSelector:@selector(checkTransparency)];
                    [w setOpaque:YES];
                    [w setBackgroundColor:NSColor.windowBackgroundColor];
                    if (view.layer) view.layer.opaque = YES;
                    [view setNeedsDisplay:YES];
                    [self fly_updateLayer];
                    logmsg("force after login-nil updateLayer win=%p opaque=%d contents=%p\n",
                           w, (int)w.isOpaque, view.layer.contents);
                } @catch (NSException *e) {
                    logmsg("login-nil force EXC %s\n", e.description.UTF8String);
                }
            });
        }
    }
}

- (void)fly_setStyleMask:(NSUInteger)mask
{
    if (force_cocoa_fast && fly_is_upc_process() && !cocoa_user_closed &&
        [self isKindOfClass:[NSWindow class]]) {
        NSWindow *w = (NSWindow *)self;
        if (fly_is_ea_title(w) && fly_window_is_primary_ea(w)) {
            mask |= NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                    NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
                    NSWindowStyleMaskFullSizeContentView;
        }
    }
    [self fly_setStyleMask:mask];
}

- (void)fly_performClose:(id)sender
{
    if (force_cocoa_fast && fly_is_upc_process() && [self isKindOfClass:[NSWindow class]]) {
        NSWindow *w = (NSWindow *)self;
        if (fly_is_ea_title(w) || fly_window_is_primary_ea(w)) {
            fly_user_close_ea(w);
            return;
        }
    }
    [self fly_performClose:sender];
}

- (void)fly_mouseDown:(NSEvent *)ev
{
    if (fly_queue_cef_mouse((NSView *)self, ev, 0, 1))
        return;
    [self fly_mouseDown:ev];
}

- (void)fly_mouseUp:(NSEvent *)ev
{
    if (fly_queue_cef_mouse((NSView *)self, ev, 0, 0))
        return;
    [self fly_mouseUp:ev];
}

- (void)fly_rightMouseDown:(NSEvent *)ev
{
    if (fly_queue_cef_mouse((NSView *)self, ev, 1, 1))
        return;
    [self fly_rightMouseDown:ev];
}

- (void)fly_rightMouseUp:(NSEvent *)ev
{
    if (fly_queue_cef_mouse((NSView *)self, ev, 1, 0))
        return;
    [self fly_rightMouseUp:ev];
}

- (void)fly_mouseDragged:(NSEvent *)ev
{
    [self fly_mouseDragged:ev];
}

- (void)fly_scrollWheel:(NSEvent *)ev
{
    [self fly_scrollWheel:ev];
}

- (void)fly_keyDown:(NSEvent *)ev
{
    if (fly_queue_cef_key(ev, 1))
        return;
    [self fly_keyDown:ev];
}

- (void)fly_keyUp:(NSEvent *)ev
{
    if (fly_queue_cef_key(ev, 0))
        return;
    [self fly_keyUp:ev];
}

@end

/* Map Cocoa WineContentView ↔ WineWindow.hwnd / .surface (macdrv).
 * Answers: does the 1454×934 view's window carry the same hwnd Option B SetDIBits? */
static void fly_surface_map_dump(const char *why)
{
    Class contentCls;
    Class wineWinCls;
    NSArray<NSWindow *> *windows;
    int n = 0;
    long long now;
    struct stat st;

    if (!force_surface_map && !force_surface_map_post)
        return;
    if (!fly_is_upc_process())
        return;
    /* Cold map wedges StartView — post mode waits for GPU login dump file. */
    if (force_surface_map_post && !force_surface_map) {
        if (!bridge_bgra_path[0] || stat(bridge_bgra_path, &st) != 0 || st.st_size < 1000000)
            return;
        if (surface_map_post_dumps >= 4)
            return;
    }
    now = inject_now_ms();
    if (last_surface_map_ms && now - last_surface_map_ms < 5000 &&
        !(why && strncmp(why, "login-nil", 9) == 0))
        return;
    last_surface_map_ms = now;
    if (force_surface_map_post && !force_surface_map)
        surface_map_post_dumps++;

    contentCls = NSClassFromString(@"WineContentView");
    wineWinCls = NSClassFromString(@"WineWindow");
    if (!contentCls)
        return;
    windows = [NSApplication sharedApplication].windows;
    logmsg("SURFACE_MAP begin why=%s wineWinCls=%p wins=%lu parent=%d bridge=%d sync=%d opaque=%d\n",
           why ? why : "?", wineWinCls, (unsigned long)windows.count,
           force_parent_present, force_login_bridge, force_login_sync, force_opaque);
    for (NSWindow *win in windows) {
        NSView *cv = win.contentView;
        void *hwnd = NULL;
        void *surface = NULL;
        int ppa = -1;
        NSMutableArray<NSView *> *stack;
        if (!cv)
            continue;
        if (wineWinCls && [win isKindOfClass:wineWinCls]) {
            /* KVC on NSKVONotifying_WineWindow often returns nil for hwnd/surface —
             * read ivars directly (macdrv WineWindow layout). */
            Ivar ih = class_getInstanceVariable(object_getClass(win), "hwnd");
            Ivar isurf = class_getInstanceVariable(object_getClass(win), "surface");
            Ivar ippa = class_getInstanceVariable(object_getClass(win), "usePerPixelAlpha");
            if (!ih) ih = class_getInstanceVariable(wineWinCls, "hwnd");
            if (!isurf) isurf = class_getInstanceVariable(wineWinCls, "surface");
            if (!ippa) ippa = class_getInstanceVariable(wineWinCls, "usePerPixelAlpha");
            if (ih) hwnd = *(void **)((char *)(__bridge void *)win + ivar_getOffset(ih));
            if (isurf) surface = *(void **)((char *)(__bridge void *)win + ivar_getOffset(isurf));
            if (ippa) ppa = *(BOOL *)((char *)(__bridge void *)win + ivar_getOffset(ippa)) ? 1 : 0;
            if (!ih && !isurf) {
                @try { hwnd = [[win valueForKey:@"hwnd"] pointerValue]; } @catch (NSException *e) {}
                @try { surface = [[win valueForKey:@"surface"] pointerValue]; } @catch (NSException *e) {}
                @try { ppa = [[win valueForKey:@"usePerPixelAlpha"] boolValue] ? 1 : 0; } @catch (NSException *e) {}
            }
        }
        /* Splash-noise filter: only log sizable / login-ish windows. */
        if (win.frame.size.width < 600.0 && win.frame.size.height < 400.0)
            continue;
        logmsg("SURFACE_MAP win=%p class=%s frame=%.0fx%.0f hwnd=%p surface=%p ppa=%d key=%d main=%d opaque=%d vis=%d level=%ld order=%ld\n",
               win, object_getClassName(win), win.frame.size.width, win.frame.size.height,
               hwnd, surface, ppa, (int)win.isKeyWindow, (int)win.isMainWindow, (int)win.isOpaque,
               (int)win.isVisible, (long)win.level, (long)win.orderedIndex);
        stack = [NSMutableArray arrayWithObject:cv];
        for (NSUInteger i = 0; i < stack.count; i++) {
            NSView *v = stack[i];
            CGFloat bw, bh;
            id contents;
            if (v.subviews.count)
                [stack addObjectsFromArray:v.subviews];
            if (![v isKindOfClass:contentCls])
                continue;
            bw = v.bounds.size.width;
            bh = v.bounds.size.height;
            if (bw < 200.0 || bh < 100.0)
                continue;
            contents = v.layer ? v.layer.contents : nil;
            n++;
            logmsg("SURFACE_MAP view#%d=%p bounds=%.0fx%.0f contents=%p win=%p hwnd=%p surface=%p ppa=%d\n",
                   n, v, bw, bh, contents, win, hwnd, surface, ppa);
        }
    }
    logmsg("SURFACE_MAP end views=%d why=%s\n", n, why ? why : "?");
}

static void try_swizzle(void)
{
    pthread_mutex_lock(&swiz_mu);
    if (swizzle_done) { pthread_mutex_unlock(&swiz_mu); return; }
    Class content = NSClassFromString(@"WineContentView");
    Class window = NSClassFromString(@"WineWindow");
    logmsg("classes WineContentView=%p WineWindow=%p\n", content, window);
    if (content) {
        swizzle(content, @selector(setColorImage:), @selector(fly_setColorImage:));
        swizzle(content, @selector(setShapeImage:), @selector(fly_setShapeImage:));
        swizzle(content, @selector(updateLayer), @selector(fly_updateLayer));
        swizzle(content, @selector(mouseDown:), @selector(fly_mouseDown:));
        swizzle(content, @selector(mouseUp:), @selector(fly_mouseUp:));
        swizzle(content, @selector(rightMouseDown:), @selector(fly_rightMouseDown:));
        swizzle(content, @selector(rightMouseUp:), @selector(fly_rightMouseUp:));
        swizzle(content, @selector(mouseDragged:), @selector(fly_mouseDragged:));
        swizzle(content, @selector(scrollWheel:), @selector(fly_scrollWheel:));
        if (window) {
            swizzle(window, @selector(setUsePerPixelAlpha:), @selector(fly_setUsePerPixelAlpha:));
            swizzle_or_add(window, @selector(setStyleMask:), @selector(fly_setStyleMask:));
            swizzle_or_add(window, @selector(performClose:), @selector(fly_performClose:));
            swizzle_or_add(window, @selector(keyDown:), @selector(fly_keyDown:));
            swizzle_or_add(window, @selector(keyUp:), @selector(fly_keyUp:));
        }
        swizzle_done = 1;
    }
    pthread_mutex_unlock(&swiz_mu);
}

/* Poll bridge file: GPU SRC dump → upc Cocoa setColorImage and/or parent SetDIBits.
 * IMPORTANT: do NOT call Wine NtUser* on the Cocoa main queue synchronously — it
 * deadlocks wineserver and starves the bridge poll (seen 21:43 run). */
static void fly_try_apply_bridge(void)
{
    struct stat st;
    long mtime_ns;
    unsigned nz = 0;
    int iw = 0, ih = 0;
    void *bits = NULL;
    uint64_t hwnd64 = 0;
    CGImageRef bridged = NULL;

    if ((!force_login_bridge && !force_parent_present) || !bridge_bgra_path[0])
        return;
    if (stat(bridge_bgra_path, &st) != 0)
        return;
    mtime_ns = (long)st.st_mtimespec.tv_sec * 1000000000L + (long)st.st_mtimespec.tv_nsec;
    if (mtime_ns == last_bridge_mtime_ns) {
        poll_mtime_same_sec++;
        poll_rate_tick();
        return;
    }

    /* Load once: raw bits for parent; CGImage for Cocoa. */
    fly_bgra_file_load(bridge_bgra_path, &nz, &iw, &ih, &bits, &hwnd64);
    if (!bits || nz == 0) {
        free(bits);
        agent_log("D", "bridge poll empty", "{\"nz\":0}");
        poll_rate_tick();
        return;
    }
    last_bridge_mtime_ns = mtime_ns;
    last_bridge_nz = nz;

    if (force_login_bridge) {
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(bits, (size_t)iw, (size_t)ih, 8,
            (size_t)iw * 4, cs,
            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        bridged = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
        if (ctx) CGContextRelease(ctx);
        CGColorSpaceRelease(cs);
    }

    /* Defer parent present to upc NtUserPeekMessage hook (Wine TEB thread).
     * Cocoa/GCD GetDCEx hangs; upc has no StretchBlt after splash. */
    free(bits);
    bits = NULL;

    if (!force_login_bridge || !bridged) {
        if (bridged) CGImageRelease(bridged);
        poll_apply_sec++;
        poll_rate_tick();
        return;
    }

    Class contentCls = NSClassFromString(@"WineContentView");
    if (!contentCls) { CGImageRelease(bridged); return; }

    NSArray<NSWindow *> *windows = [NSApplication sharedApplication].windows;
    id target = nil;
    CGFloat best_score = -1.0;
    int cand_n = 0;
    for (NSWindow *win in windows) {
        NSView *cv = win.contentView;
        if (!cv) continue;
        NSMutableArray<NSView *> *stack = [NSMutableArray arrayWithObject:cv];
        for (NSUInteger i = 0; i < stack.count; i++) {
            NSView *v = stack[i];
            if (v.subviews.count) [stack addObjectsFromArray:v.subviews];
            if (![v isKindOfClass:contentCls]) continue;
            CGFloat bw = v.bounds.size.width;
            CGFloat bh = v.bounds.size.height;
            if (bw < 400.0 || bh < 400.0) continue;
            cand_n++;
            CGFloat dw = fabs(bw - (CGFloat)iw);
            CGFloat dh = fabs(bh - (CGFloat)ih);
            CGFloat score = 1000000.0 - (dw + dh) * 10.0 + bw * bh * 0.0001;
            if (dw <= (CGFloat)iw * 0.05 + 8.0 && dh <= (CGFloat)ih * 0.05 + 8.0)
                score += 500000.0;
            if (bw >= 1400.0 && bh >= 900.0) score += 50000.0;
            if (win.isKeyWindow || win.isMainWindow) score += 10000.0;
            if (score > best_score) {
                best_score = score;
                target = v;
            }
            if (cand_n <= 8) {
                logmsg("login-bridge cand#%d view=%p bounds=%.0fx%.0f img=%dx%d score=%.0f key=%d\n",
                       cand_n, v, bw, bh, iw, ih, score,
                       (int)(win.isKeyWindow || win.isMainWindow));
            }
        }
    }
    if (!target) {
        logmsg("login-bridge poll: no WineContentView yet (nz=%u)\n", nz);
        CGImageRelease(bridged);
        return;
    }

    NSView *view = (NSView *)target;
    NSWindow *w = view.window;
    @try {
        if ([w respondsToSelector:@selector(setUsePerPixelAlpha:)])
            [w setValue:@NO forKey:@"usePerPixelAlpha"];
        if ([target respondsToSelector:@selector(setShapeImage:)])
            ((void (*)(id, SEL, CGImageRef))objc_msgSend)(target, @selector(setShapeImage:), NULL);
        [w setOpaque:YES];
        if (view.layer) view.layer.opaque = YES;
        ((void (*)(id, SEL, CGImageRef))objc_msgSend)(target, @selector(setColorImage:), bridged);
        if (view.layer) {
            view.layer.contents = (__bridge id)bridged;
            view.layer.contentsGravity = kCAGravityResize;
            [view.layer setNeedsDisplay];
        }
        if ([w respondsToSelector:@selector(checkTransparency)])
            [w performSelector:@selector(checkTransparency)];
        [view setNeedsDisplay:YES];
        [view displayIfNeeded];
        login_bridge_done = 1;
        poll_apply_sec++;
        logmsg("login-bridge poll setColorImage view=%p %dx%d nz=%u contents=%p bounds=%.0fx%.0f cands=%d hwnd=0x%llx\n",
               target, iw, ih, nz, view.layer.contents,
               view.bounds.size.width, view.bounds.size.height, cand_n,
               (unsigned long long)hwnd64);
    } @catch (NSException *e) {
        logmsg("login-bridge poll EXC %s\n", e.description.UTF8String);
    }
    CGImageRelease(bridged);
    poll_rate_tick();
}

static void fly_try_apply_fast_shm(void)
{
    unsigned nz = 0;
    int fw = 0, fh = 0;
    CGImageRef img;
    Class contentCls;
    NSWindow *primary;
    long long now;
    if (!force_cocoa_fast || !fly_is_upc_process() || cocoa_user_closed)
        return;
    img = fly_shm4_cgimage(&nz, &fw, &fh);
    now = inject_now_ms();
    contentCls = NSClassFromString(@"WineContentView");
    primary = fly_primary_ea_window();
    if (primary && primary.frame.size.width >= 900.0) {
        cocoa_library_mode = 1;
        cocoa_last_fw = (int)primary.frame.size.width;
        cocoa_last_fh = (int)primary.frame.size.height;
    }
    if (cocoa_library_mode && primary)
        fly_order_out_ea_ghosts(primary);
    if (primary) {
        NSView *cv = primary.contentView;
        fly_ensure_ea_chrome(primary);
        fly_ensure_ea_window_visible(primary);
        if (cv) {
            NSMutableArray<NSView *> *stack = [NSMutableArray arrayWithObject:cv];
            for (NSUInteger i = 0; i < stack.count; i++) {
                NSView *v = stack[i];
                if (v.subviews.count)
                    [stack addObjectsFromArray:v.subviews];
                if (contentCls && ![v isKindOfClass:contentCls])
                    continue;
                if (img)
                    fly_apply_shm4_to_view(v, img, fw, fh, nz, "poll");
                else if (!last_cocoa_good_ms || now - last_cocoa_good_ms > 2000) {
                    fly_show_metal_views(primary);
                    fly_ensure_ea_window_visible(primary);
                }
                break;
            }
        }
    }
    if (img)
        CGImageRelease(img);
    else if (primary && (!last_cocoa_good_ms || now - last_cocoa_good_ms > 2000) &&
             fly_cocoa_rate(&last_cocoa_log_ms, 1000))
        logmsg("cocoa-fast no FLY4 frame — Metal fallback (good_ms=%lld)\n",
               last_cocoa_good_ms);
}

@interface FlyPresentForceBootstrap : NSObject
@end
@implementation FlyPresentForceBootstrap
+ (void)load
{
    const char *fo = getenv("PRESENT_FORCE_OPAQUE");
    if (fo && fo[0] == '0') force_opaque = 0;
    const char *fl = getenv("PRESENT_FORCE_LOGIN_FILL");
    if (fl && fl[0] == '1') force_login_fill = 1;
    const char *fs = getenv("PRESENT_FORCE_LOGIN_SYNC");
    if (fs && fs[0] == '1') force_login_sync = 1;
    const char *fb = getenv("PRESENT_FORCE_LOGIN_BRIDGE");
    if (fb && fb[0] == '1') force_login_bridge = 1;
    const char *fsm = getenv("FLY_SURFACE_MAP");
    if (fsm && fsm[0] == '1') force_surface_map = 1;
    if (fsm && (strcmp(fsm, "post") == 0 || strcmp(fsm, "POST") == 0))
        force_surface_map_post = 1;
    const char *fpp = getenv("FLY_PARENT_PRESENT");
    if (fpp && fpp[0] == '1') force_parent_present = 1;
    const char *fcf = getenv("FLY_COCOA_FAST");
    if (fcf && fcf[0] == '1') force_cocoa_fast = 1;
    /* Do NOT auto-enable cold surface map from sync — wedges StartView. */
    const char *bp = getenv("PRESENT_BRIDGE_BGRA");
    if (bp && *bp) {
        snprintf(bridge_bgra_path, sizeof(bridge_bgra_path), "%s", bp);
    } else {
        snprintf(bridge_bgra_path, sizeof(bridge_bgra_path),
                 "%s/Library/Containers/com.fly.gaming/Bottles/32050D6B-F756-491C-8CBF-8C4CAC1B5ECF/drive_c/windows/temp/fly-stretch-bridge.bgra",
                 getenv("HOME") ? getenv("HOME") : "");
    }
    ensure_proc_label();
    /* Create /tmp/fly-bnet-metal-host at +load. Keep only a *live* GPU
     * record (owner_pid still running). R22 kept hwnd=0x100f2 cid=… after
     * Agent/client died — stale CAContext. Do not wipe a live GET_SURFACE. */
    {
        struct fly_mtlh z;
        memset(&z, 0, sizeof(z));
        if (mtlh_sys_read(&z) == 0 && z.magic == MTLH_MAGIC && z.hwnd &&
            z.owner_pid && kill((pid_t)z.owner_pid, 0) == 0) {
            logmsg("mtlh: +load keep live file %s hwnd=0x%x cid=%u pid=%u\n",
                   MTLH_FILE, z.hwnd, z.context_id, z.owner_pid);
        } else {
            memset(&z, 0, sizeof(z));
            if (mtlh_sys_write(&z) == 0)
                logmsg("mtlh: +load reset file %s (stale or empty)\n", MTLH_FILE);
            else
                logmsg("mtlh: +load file %s FAILED\n", MTLH_FILE);
        }
    }
    logmsg("present_force_inject +load force_opaque=%d force_login_fill=%d force_login_sync=%d force_login_bridge=%d cocoa_fast=%d surface_map=%d map_post=%d parent_present=%d upc=%d shm=%s bridge=%s\n",
           force_opaque, force_login_fill, force_login_sync, force_login_bridge, force_cocoa_fast,
           force_surface_map, force_surface_map_post, force_parent_present, fly_is_upc_process(),
           shm4_name(), bridge_bgra_path);
    agent_log("E", "inject load", force_login_bridge ? "{\"bridge\":1}" : "{\"bridge\":0}");
    /* Wine classes may not exist yet — retry shortly */
    try_swizzle();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ try_swizzle(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ try_swizzle(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ try_swizzle(); });
    if (!force_cocoa_fast) {
        dispatch_source_t mtlh = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                        dispatch_get_main_queue());
        dispatch_source_set_timer(mtlh, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                                  (uint64_t)(0.4 * NSEC_PER_SEC), (uint64_t)(0.1 * NSEC_PER_SEC));
        dispatch_source_set_event_handler(mtlh, ^{
            /* Do not create NSApp. Wait for macdrv WineApplication. */
            if (!NSApp) {
                static long long last;
                if (fly_cocoa_rate(&last, 2000))
                    logmsg("mtlh: wait Wine NSApp (no sharedApplication)\n");
                return;
            }
            if (fly_is_bnet_gpu())
                fly_publish_gpu_metal();
            else if (fly_is_bnet_parent())
                fly_host_follow_largest();
        });
        dispatch_resume(mtlh);
        static dispatch_source_t mtlh_timer;
        mtlh_timer = mtlh;
        (void)mtlh_timer;
    }
    if (force_login_bridge || force_cocoa_fast || force_surface_map || force_surface_map_post || force_parent_present) {
        /* Argv may not list upc.exe at +load — retry timer arm for a few seconds. */
        __block int armed = 0;
        void (^try_arm)(void) = ^{
            if (armed) return;
            if (!fly_is_upc_process()) {
                logmsg("inject timer wait upc=%d\n", fly_is_upc_process());
                return;
            }
            armed = 1;
            logmsg("inject timer arm upc=1 map=%d post=%d\n", force_surface_map, force_surface_map_post);
            dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                             dispatch_get_main_queue());
            dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                                      (uint64_t)(0.5 * NSEC_PER_SEC), (uint64_t)(0.1 * NSEC_PER_SEC));
            dispatch_source_set_event_handler(timer, ^{
                try_swizzle();
                if (force_login_bridge || force_parent_present)
                    fly_try_apply_bridge();
                if (force_cocoa_fast)
                    fly_try_apply_fast_shm();
                if (force_surface_map || force_surface_map_post)
                    fly_surface_map_dump(force_surface_map_post && !force_surface_map ? "post-bridge" : "timer");
            });
            dispatch_resume(timer);
            static dispatch_source_t bridge_timer;
            bridge_timer = timer;
            (void)bridge_timer;
        };
        try_arm();
        for (int d = 1; d <= 8; d++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * 0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), try_arm);
        }
    }
}
@end
