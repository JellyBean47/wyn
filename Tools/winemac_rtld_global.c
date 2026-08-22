/*
 * winemac_rtld_global.c — Battle.net / DXMT only.
 *
 * Round 6: promote frankea winemac.so with RTLD_NOLOAD|RTLD_GLOBAL so
 *   dlsym(RTLD_DEFAULT, "macdrv_functions") works (3Shain/dxmt#170).
 *   Do NOT DYLD_INTERPOSE dlopen (deadlocks Foundation init).
 *
 * Round 7: 3Shain/dxmt#166 / Wine MR 11058 ExtEscape GET_SURFACE.
 *   Current frankea DXMT (June 2025) never calls ExtEscape; it still uses
 *   CreateMetalViewFromHWND → macdrv_functions.get_win_data.
 *   frankea my_get_win_data (winemac.so 0x20eb0) does get_win_data(hwnd)
 *   FIRST (process-local CFDictionary) and returns NULL for a foreign HWND,
 *   so it never reaches macdrv_client_surface_create (0x37670) — the same
 *   create ExtEscape would call (NtUserGetAncestor + macdrv_create_view +
 *   client_surface_update). Replace get_win_data with a shim that, on NULL,
 *   calls that create and returns a DXMT-layout {client_cocoa_view}.
 *
 * Round 8: CEF renderer ImmediateCrash at libcef RVA 0x16D00E1 (EIP 6DD700E1).
 *   After VirtualProtect(addr, size, PAGE_READONLY=2, &old) succeeds, Chromium
 *   CHECKs old == PAGE_READWRITE (4). Wine reports PAGE_EXECUTE_READWRITE
 *   (0x40) for those pages. Hook unix NtProtectVirtualMemory and lie old=4
 *   when new_prot is PAGE_READONLY. Install on ntdll.so add_image (renderer
 *   may never load winemac). Do NOT DYLD_INTERPOSE.
 *
 * Round 11: publish GET_SURFACE view* (posix shm failed — Wine shm_open).
 * Round 12: same view* via regular file + raw syscall(SYS_open/pwrite).
 *   Do not walk NSApplication.windows.
 *
 * clang -arch x86_64 -dynamiclib -O2 -o Tools/bin/winemac_rtld_global.dylib \
 *   Tools/winemac_rtld_global.c
 */

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

#define PAGE_READONLY 0x02u
#define PAGE_READWRITE 0x04u
#define STATUS_SUCCESS 0
#define NTPROTECT_STEAL 20

#define MACDRV_CLIENT_SURFACE_CREATE 0x37670ul
#define MACDRV_CLIENT_SURFACE_CREATE_INSN 0xe5894855u /* pushq %rbp; movq %rsp,%rbp */
#define DXMT_WIN_DATA_SIZE 0x78
#define DXMT_CLIENT_VIEW_OFF 0x18
#define SURFACE_COCOA_VIEW_OFF 0x30
#define WRAP_ORIG_OFF 0x68

#define MTLH_MAGIC 0x4D544C48u /* MTLH */
#define MTLH_FILE "/tmp/fly-bnet-metal-host"

/* Must match Tools/present_force_inject.m */
struct fly_mtlh {
    uint32_t magic;
    uint32_t context_id;
    uint32_t width, height;
    uint32_t owner_pid;
    uint32_t hwnd;
    uint64_t view;
    uint32_t view_pid;
    uint32_t pad;
};

struct macdrv_functions_t {
    void (*macdrv_init_display_devices)(int);
    void *(*get_win_data)(void *hwnd);
    void (*release_win_data)(void *data);
    void *(*macdrv_get_cocoa_window)(void *hwnd, int require_on_screen);
    void *(*macdrv_create_metal_device)(void);
    void (*macdrv_release_metal_device)(void *d);
    void *(*macdrv_view_create_metal_view)(void *v, void *d);
    void *(*macdrv_view_get_metal_layer)(void *v);
    void (*macdrv_view_release_metal_view)(void *v);
    void (*on_main_thread)(void *b);
};

static void *(*orig_get_win_data)(void *);
static void (*orig_release_win_data)(void *);
static void *(*macdrv_client_surface_create)(void *);
static int shim_installed;

typedef int (*ntprotect_fn)(void *, void **, unsigned long *, unsigned, unsigned *);
static ntprotect_fn orig_ntprotect;
static int protect_hooked;

static void logline(const char *fmt, ...)
{
    const char *path = getenv("WINEMAC_RTLD_GLOBAL_LOG");
    FILE *f = NULL;
    va_list ap;

    if (path && path[0])
        f = fopen(path, "a");
    if (!f)
        f = stderr;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fflush(f);
    if (f != stderr)
        fclose(f);
}

static int is_winemac(const char *path)
{
    if (!path)
        return 0;
    if (strstr(path, "winemetal"))
        return 0;
    return strstr(path, "winemac.so") || strstr(path, "winemac.drv");
}

/* Round 12: Wine interposes libc shm_open/open (R11 ftruncate errno=22).
 * Raw `syscall` on a regular file — DYLD_INTERPOSE cannot steal it. */
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

/* GPU GET_SURFACE view is an orphan macdrv_create_view — not in any
 * NSWindow. Write the process-local pointer so present_force_inject can
 * CAContext it. Parent must not dereference view; only GPU does. */
static void publish_get_surface_view(void *hwnd, void *view)
{
    struct fly_mtlh m;

    if (!view)
        return;
    memset(&m, 0, sizeof(m));
    (void)mtlh_sys_read(&m); /* keep context_id / size if inject already hosted */
    m.magic = MTLH_MAGIC;
    m.hwnd = (uint32_t)(uintptr_t)hwnd;
    m.view = (uint64_t)(uintptr_t)view;
    m.view_pid = (uint32_t)getpid();
    if (mtlh_sys_write(&m) != 0) {
        logline("mtlh: syscall pwrite %s failed errno=%d\n", MTLH_FILE, errno);
        return;
    }
    logline("mtlh: published GET_SURFACE view=%p hwnd=%p pid=%d file=%s\n",
            view, hwnd, (int)getpid(), MTLH_FILE);
}

static void *shim_get_win_data(void *hwnd)
{
    void *data;
    void *surface;
    void *view;
    unsigned char *wrap;

    if (orig_get_win_data) {
        data = orig_get_win_data(hwnd);
        if (data)
            return data;
    }
    if (!macdrv_client_surface_create || !hwnd) {
        logline("extescape: GET_SURFACE hwnd=%p skip (create=%p)\n",
                hwnd, (void *)macdrv_client_surface_create);
        return NULL;
    }
    /* Wine MR 11058 / #166: create a client surface in THIS pid and attach
     * it to the (possibly foreign) HWND via wineserver. No local win_datas. */
    surface = macdrv_client_surface_create(hwnd);
    if (!surface) {
        logline("extescape: client_surface_create(%p) failed\n", hwnd);
        return NULL;
    }
    view = *(void **)((char *)surface + SURFACE_COCOA_VIEW_OFF);
    wrap = calloc(1, DXMT_WIN_DATA_SIZE);
    if (!wrap)
        return NULL;
    memcpy(wrap, &hwnd, sizeof(hwnd));
    memcpy(wrap + DXMT_CLIENT_VIEW_OFF, &view, sizeof(view));
    /* +0x68 NULL → orig release_win_data calls get_win_data unlock on NULL */
    logline("extescape: GET_SURFACE hwnd=%p surface=%p view=%p wrap=%p\n",
            hwnd, surface, view, wrap);
    publish_get_surface_view(hwnd, view);
    return wrap;
}

static void shim_release_win_data(void *data)
{
    if (orig_release_win_data)
        orig_release_win_data(data);
}

static int is_ntdll_unix(const char *path)
{
    return path && strstr(path, "ntdll.so") && strstr(path, "x86_64-unix");
}

static int hook_ntprotect(void *process, void **addr, unsigned long *size,
                          unsigned newp, unsigned *oldp)
{
    int st;

    st = orig_ntprotect(process, addr, size, newp, oldp);
    if (newp == PAGE_READONLY && oldp) {
        unsigned was = *oldp;

        if (st != STATUS_SUCCESS || was != PAGE_READWRITE) {
            logline("protect: lie status=%x old=%x -> 4 PAGE_READONLY addr=%p\n",
                    (unsigned)st, was, addr ? *addr : NULL);
            *oldp = PAGE_READWRITE;
            return STATUS_SUCCESS;
        }
    }
    return st;
}

static int make_rwx(void *p, size_t n)
{
    long ps = sysconf(_SC_PAGESIZE);
    uintptr_t start = (uintptr_t)p & ~((uintptr_t)ps - 1);
    uintptr_t end = ((uintptr_t)p + n + (uintptr_t)ps - 1) & ~((uintptr_t)ps - 1);

    return mprotect((void *)start, (size_t)(end - start),
                    PROT_READ | PROT_WRITE | PROT_EXEC);
}

static void install_protect_hook(void)
{
    uint32_t i, n;
    const char *path = NULL;
    void *h, *fn;
    unsigned char *src;
    unsigned char *tramp;
    uintptr_t back;
    static const unsigned char want[] = {
        0x55, 0x48, 0x89, 0xe5, 0x41, 0x57, 0x41, 0x56, 0x41, 0x55,
        0x41, 0x54, 0x53, 0x48, 0x81, 0xec
    };

    if (protect_hooked)
        return;
    n = _dyld_image_count();
    for (i = 0; i < n; i++) {
        path = _dyld_get_image_name(i);
        if (is_ntdll_unix(path))
            break;
        path = NULL;
    }
    if (!path)
        return;
    h = dlopen(path, RTLD_NOLOAD | RTLD_NOW);
    if (!h)
        return;
    fn = dlsym(h, "NtProtectVirtualMemory");
    if (!fn)
        fn = dlsym(h, "_NtProtectVirtualMemory");
    if (!fn) {
        logline("protect: NtProtectVirtualMemory missing in %s\n", path);
        return;
    }
    src = fn;
    if (memcmp(src, want, sizeof(want)) != 0) {
        logline("protect: prologue mismatch at %p first=%02x%02x%02x%02x\n",
                fn, src[0], src[1], src[2], src[3]);
        return;
    }
    tramp = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
                 MAP_ANON | MAP_PRIVATE, -1, 0);
    if (tramp == MAP_FAILED) {
        logline("protect: mmap trampoline failed\n");
        return;
    }
    memcpy(tramp, src, NTPROTECT_STEAL);
    back = (uintptr_t)src + NTPROTECT_STEAL;
    tramp[NTPROTECT_STEAL + 0] = 0x48;
    tramp[NTPROTECT_STEAL + 1] = 0xb8;
    memcpy(tramp + NTPROTECT_STEAL + 2, &back, sizeof(back));
    tramp[NTPROTECT_STEAL + 10] = 0xff;
    tramp[NTPROTECT_STEAL + 11] = 0xe0;
    if (make_rwx(src, NTPROTECT_STEAL) != 0) {
        logline("protect: mprotect ntdll text failed\n");
        return;
    }
    src[0] = 0x48;
    src[1] = 0xb8;
    {
        uintptr_t hook = (uintptr_t)hook_ntprotect;

        memcpy(src + 2, &hook, sizeof(hook));
    }
    src[10] = 0xff;
    src[11] = 0xe0;
    orig_ntprotect = (ntprotect_fn)(void *)tramp;
    protect_hooked = 1;
    logline("protect: hooked NtProtectVirtualMemory %p tramp=%p\n", fn, tramp);
}

static void install_get_surface_shim(void *table_sym, intptr_t slide)
{
    struct macdrv_functions_t *fn = table_sym;
    unsigned *create_insn;
    uintptr_t create_addr;

    if (shim_installed || !fn)
        return;
    create_addr = (uintptr_t)slide + MACDRV_CLIENT_SURFACE_CREATE;
    create_insn = (unsigned *)create_addr;
    if (*create_insn != MACDRV_CLIENT_SURFACE_CREATE_INSN) {
        logline("extescape: client_surface_create bytes=%08x want=%08x slide=%p\n",
                *create_insn, MACDRV_CLIENT_SURFACE_CREATE_INSN, (void *)slide);
        return;
    }
    orig_get_win_data = fn->get_win_data;
    orig_release_win_data = fn->release_win_data;
    macdrv_client_surface_create = (void *(*)(void *))create_addr;
    fn->get_win_data = shim_get_win_data;
    fn->release_win_data = shim_release_win_data;
    shim_installed = 1;
    logline("extescape: installed GET_SURFACE shim orig_get=%p create=%p\n",
            (void *)orig_get_win_data, (void *)macdrv_client_surface_create);
}

static void promote(const char *name, const struct mach_header *mh, intptr_t slide)
{
    void *h, *sym;

    if (!is_winemac(name))
        return;
    h = dlopen(name, RTLD_NOLOAD | RTLD_NOW | RTLD_GLOBAL);
    if (!h)
        return;
    sym = dlsym(RTLD_DEFAULT, "macdrv_functions");
    logline("winemac_rtld_global: add_image promoted %s macdrv_functions=%p\n",
            name, sym);
    (void)mh;
    install_get_surface_shim(sym, slide);
}

static void on_add_image(const struct mach_header *mh, intptr_t slide)
{
    Dl_info info;

    if (!dladdr(mh, &info) || !info.dli_fname)
        return;
    if (is_ntdll_unix(info.dli_fname))
        install_protect_hook();
    promote(info.dli_fname, mh, slide);
}

__attribute__((constructor))
static void winemac_rtld_global_init(void)
{
    logline("winemac_rtld_global: add_image + GET_SURFACE + VirtualProtect lie\n");
    _dyld_register_func_for_add_image(on_add_image);
}
