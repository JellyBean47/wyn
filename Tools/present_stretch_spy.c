/*
 * present_stretch_spy.c — 32-bit PE DLL: IAT + delay-IAT hook gdi32 StretchBlt,
 * dump login-size SRC (BitBlt + GetDIBits) for present bridge.
 *
 *   i686-w64-mingw32-gcc -shared -O2 -o Tools/bin/present_stretch_spy.dll \
 *       Tools/present_stretch_spy.c -lgdi32 -luser32
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <stdint.h>
#include <stdarg.h>
#include <string.h>

typedef BOOL (WINAPI *StretchBlt_fn)(HDC, int, int, int, int, HDC, int, int, int, int, DWORD);
typedef BOOL (WINAPI *BitBlt_fn)(HDC, int, int, int, int, HDC, int, int, DWORD);
typedef int (WINAPI *StretchDIBits_fn)(HDC, int, int, int, int, int, int, int, int,
                                       const void *, const BITMAPINFO *, UINT, DWORD);

static StretchBlt_fn real_StretchBlt;
static BitBlt_fn real_BitBlt;
static StretchDIBits_fn real_StretchDIBits;
static volatile LONG login_logs;
static volatile LONG login_dumps;
static HANDLE log_mu;
static char log_path[MAX_PATH];
static char bgra_path[MAX_PATH];
static volatile LONG in_hook;

static void spy_log(const char *fmt, ...)
{
    char buf[512];
    va_list ap;
    FILE *f;
    SYSTEMTIME st;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    GetLocalTime(&st);
    if (log_mu) WaitForSingleObject(log_mu, 1000);
    f = fopen(log_path, "a");
    if (f) {
        fprintf(f, "%02d:%02d:%02d.%03d [pid=%lu] %s",
                st.wHour, st.wMinute, st.wSecond, st.wMilliseconds,
                (unsigned long)GetCurrentProcessId(), buf);
        fclose(f);
    }
    if (log_mu) ReleaseMutex(log_mu);
}

/* #region agent log */
static void agent_log(const char *hid, const char *msg, const char *data_json)
{
    FILE *f = fopen("Z:\\Users\\ebenoelofse\\Desktop\\Fly\\.cursor\\debug-505da6.log", "a");
    if (!f)
        f = fopen("C:\\windows\\temp\\debug-505da6.log", "a");
    if (f) {
        fprintf(f,
                "{\"sessionId\":\"505da6\",\"hypothesisId\":\"%s\",\"location\":\"present_stretch_spy.dll\","
                "\"message\":\"%s\",\"data\":%s,\"timestamp\":%lu}\n",
                hid, msg, data_json ? data_json : "{}", (unsigned long)GetTickCount());
        fclose(f);
    }
}
/* #endregion */

static unsigned type_byte(ULONG_PTR h)
{
    return (unsigned)((h & 0x007f0000u) >> 16);
}

static const char *type_name(unsigned t)
{
    if (t == 0x01) return "DC";
    if (t == 0x41) return "MEMDC";
    return "OTHER";
}

static int dump_hdc_bgra(HDC hdc, int w, int h, const char *path, unsigned *nonzero_out)
{
    BITMAPINFO bmi;
    HDC mem;
    HBITMAP dib, old;
    void *bits;
    DWORD *p;
    int n, i;
    unsigned nz = 0;
    FILE *f;
    int wrote = 0;

    *nonzero_out = 0;
    if (w < 8 || h < 8 || !hdc) return -1;
    ZeroMemory(&bmi, sizeof(bmi));
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = w;
    bmi.bmiHeader.biHeight = -h;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;
    mem = CreateCompatibleDC(hdc);
    if (!mem) return -2;
    dib = CreateDIBSection(mem, &bmi, DIB_RGB_COLORS, &bits, NULL, 0);
    if (!dib || !bits) {
        DeleteDC(mem);
        return -3;
    }
    old = (HBITMAP)SelectObject(mem, dib);
    BitBlt(mem, 0, 0, w, h, hdc, 0, 0, SRCCOPY);
    GdiFlush();
    n = w * h;
    p = (DWORD *)bits;
    for (i = 0; i < n; i++)
        if (p[i] & 0x00FFFFFF) nz++;
    *nonzero_out = nz;
    f = fopen(path, "wb");
    if (f) {
        fwrite(&w, 4, 1, f);
        fwrite(&h, 4, 1, f);
        fwrite(bits, 4, (size_t)n, f);
        fclose(f);
        wrote = 1;
    }
    SelectObject(mem, old);
    DeleteObject(dib);
    DeleteDC(mem);
    return wrote ? 0 : -4;
}

/* Direct GetDIBits on the selected bitmap — catches DIBSECTION SRC that BitBlt misses. */
static int dump_selected_dib(HDC hdc, int w, int h, const char *path, unsigned *nonzero_out)
{
    HBITMAP hb;
    BITMAP bm;
    BITMAPINFO bmi;
    void *bits;
    DWORD *p;
    int n, i, lines;
    unsigned nz = 0;
    FILE *f;

    *nonzero_out = 0;
    if (!hdc || w < 8 || h < 8) return -1;
    hb = (HBITMAP)GetCurrentObject(hdc, OBJ_BITMAP);
    if (!hb) return -2;
    if (!GetObjectA(hb, sizeof(bm), &bm)) return -3;
    if (bm.bmWidth < 8 || bm.bmHeight < 8) return -4;
    if (w > bm.bmWidth) w = bm.bmWidth;
    if (h > (bm.bmHeight < 0 ? -bm.bmHeight : bm.bmHeight))
        h = bm.bmHeight < 0 ? -bm.bmHeight : bm.bmHeight;
    n = w * h;
    bits = HeapAlloc(GetProcessHeap(), 0, (SIZE_T)n * 4);
    if (!bits) return -5;
    ZeroMemory(&bmi, sizeof(bmi));
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = w;
    bmi.bmiHeader.biHeight = -h;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;
    lines = GetDIBits(hdc, hb, 0, h, bits, &bmi, DIB_RGB_COLORS);
    if (lines <= 0) {
        HeapFree(GetProcessHeap(), 0, bits);
        return -6;
    }
    p = (DWORD *)bits;
    for (i = 0; i < n; i++)
        if (p[i] & 0x00FFFFFF) nz++;
    *nonzero_out = nz;
    f = fopen(path, "wb");
    if (!f) {
        HeapFree(GetProcessHeap(), 0, bits);
        return -7;
    }
    fwrite(&w, 4, 1, f);
    fwrite(&h, 4, 1, f);
    fwrite(bits, 4, (size_t)n, f);
    fclose(f);
    HeapFree(GetProcessHeap(), 0, bits);
    return 0;
}

static void maybe_bridge_copy(const char *spath, unsigned snz)
{
    if (snz > 0) {
        CopyFileA(spath, bgra_path, FALSE);
        InterlockedIncrement(&login_dumps);
        spy_log("  bridge copy -> %s (nz=%u)\n", bgra_path, snz);
    }
}

static volatile LONG any_logs;
static void handle_login_src(HDC hdcSrc, int sw, int sh, const char *api, LONG n);

static BOOL WINAPI hooked_StretchBlt(HDC hdcDst, int xDst, int yDst, int wDst, int hDst,
                                     HDC hdcSrc, int xSrc, int ySrc, int wSrc, int hSrc,
                                     DWORD rop)
{
    BOOL ret;
    int interesting;
    LONG nany;

    if (InterlockedCompareExchange(&in_hook, 1, 0) != 0)
        return real_StretchBlt(hdcDst, xDst, yDst, wDst, hDst,
                               hdcSrc, xSrc, ySrc, wSrc, hSrc, rop);

    /* ALWAYS call real blit first — pre-blit BitBlt/GetDIBits on CEF SRC can
     * hang/kill the drawer (hyp F: Close→1454 HWND then death, zero LOGIN_BLIT). */
    ret = real_StretchBlt(hdcDst, xDst, yDst, wDst, hDst,
                          hdcSrc, xSrc, ySrc, wSrc, hSrc, rop);

    interesting = (wDst >= 1400 && hDst >= 900) || (wSrc >= 1400 && hSrc >= 900);
    /* Light proof hooks work — avoid fopen spam on the CEF hot path. */
    nany = InterlockedIncrement(&any_logs);
    if (nany == 1 || (interesting && login_logs == 0)) {
        spy_log("BLIT_SEE #%ld %dx%d<-%dx%d interesting=%d\n",
                (long)nany, wDst, hDst, wSrc, hSrc, interesting);
        agent_log("C", "blit seen", interesting ? "{\"interesting\":1}" : "{\"interesting\":0}");
    }

    if (interesting && login_logs < 64) {
        HWND hwnd = WindowFromDC(hdcDst);
        unsigned st = type_byte((ULONG_PTR)hdcSrc);
        unsigned dt = type_byte((ULONG_PTR)hdcDst);
        char json[384];
        LONG n = InterlockedIncrement(&login_logs);
        int sw = wSrc > 0 ? wSrc : wDst;
        int sh = hSrc > 0 ? hSrc : hDst;

        spy_log("LOGIN_BLIT #%ld ret=%d dst=%p(%s) src=%p(%s) hwnd=%p "
                "dstWH=%dx%d srcWH=%dx%d xy=%d,%d rop=%08lx\n",
                (long)n, (int)ret,
                (void *)hdcDst, type_name(dt),
                (void *)hdcSrc, type_name(st),
                (void *)hwnd,
                wDst, hDst, wSrc, hSrc, xDst, yDst, (unsigned long)rop);

        snprintf(json, sizeof(json),
                 "{\"n\":%ld,\"ret\":%d,\"dst\":\"%p\",\"dstType\":\"%s\","
                 "\"src\":\"%p\",\"srcType\":\"%s\",\"hwnd\":\"%p\","
                 "\"dstWH\":[%d,%d],\"srcWH\":[%d,%d]}",
                 (long)n, (int)ret, (void *)hdcDst, type_name(dt),
                 (void *)hdcSrc, type_name(st), (void *)hwnd,
                 wDst, hDst, wSrc, hSrc);
        agent_log("C", "login StretchBlt", json);
        handle_login_src(hdcSrc, sw, sh, "StretchBlt", n);
    }
    InterlockedExchange(&in_hook, 0);
    return ret;
}

static int patch_slot(void **slot, void *orig, void *hook)
{
    DWORD old;
    if (!slot || *slot != orig) return 0;
    if (!VirtualProtect(slot, sizeof(void *), PAGE_READWRITE, &old)) return 0;
    *slot = hook;
    VirtualProtect(slot, sizeof(void *), old, &old);
    return 1;
}

static int patch_iat_module(HMODULE mod, void *orig, void *hook)
{
    BYTE *base;
    IMAGE_DOS_HEADER *dos;
    IMAGE_NT_HEADERS *nt;
    IMAGE_IMPORT_DESCRIPTOR *imp;
    DWORD rva;
    int patched = 0;

    if (!mod || !orig || !hook) return 0;
    base = (BYTE *)mod;
    dos = (IMAGE_DOS_HEADER *)base;
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return 0;
    nt = (IMAGE_NT_HEADERS *)(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return 0;
    rva = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress;
    if (!rva) return 0;
    imp = (IMAGE_IMPORT_DESCRIPTOR *)(base + rva);
    for (; imp->Name; imp++) {
        char *dll = (char *)(base + imp->Name);
        IMAGE_THUNK_DATA *thunk;
        IMAGE_THUNK_DATA *othunk;
        if (!dll) continue;
        if (lstrcmpiA(dll, "gdi32.dll") != 0) continue;
        thunk = (IMAGE_THUNK_DATA *)(base + imp->FirstThunk);
        othunk = imp->OriginalFirstThunk
                     ? (IMAGE_THUNK_DATA *)(base + imp->OriginalFirstThunk)
                     : thunk;
        for (; othunk->u1.AddressOfData; thunk++, othunk++) {
            patched += patch_slot((void **)&thunk->u1.Function, orig, hook);
        }
    }
    return patched;
}

/* libcef delay-imports BitBlt/StretchBlt/StretchDIBits — patch by export name. */
static int patch_delay_iat_named(HMODULE mod, const char *fn_name, void *hook)
{
    BYTE *base;
    IMAGE_DOS_HEADER *dos;
    IMAGE_NT_HEADERS *nt;
    DWORD rva, size, off;
    int patched = 0;
    typedef struct {
        DWORD attributes;
        DWORD rvaDLLName;
        DWORD rvaHmod;
        DWORD rvaIAT;
        DWORD rvaINT;
        DWORD rvaBoundIAT;
        DWORD rvaUnloadIAT;
        DWORD timeDateStamp;
    } ImgDelayDescr;

    if (!mod || !hook || !fn_name) return 0;
    base = (BYTE *)mod;
    dos = (IMAGE_DOS_HEADER *)base;
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return 0;
    nt = (IMAGE_NT_HEADERS *)(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return 0;
    rva = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT].VirtualAddress;
    size = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT].Size;
    if (!rva || !size) return 0;

    for (off = 0; off + sizeof(ImgDelayDescr) <= size; off += sizeof(ImgDelayDescr)) {
        ImgDelayDescr *d = (ImgDelayDescr *)(base + rva + off);
        char *dll;
        IMAGE_THUNK_DATA *thunk, *othunk;
        if (!d->rvaDLLName || !d->rvaIAT || !d->rvaINT) break;
        dll = (char *)(base + d->rvaDLLName);
        if (lstrcmpiA(dll, "gdi32.dll") != 0) continue;
        thunk = (IMAGE_THUNK_DATA *)(base + d->rvaIAT);
        othunk = (IMAGE_THUNK_DATA *)(base + d->rvaINT);
        for (; othunk->u1.AddressOfData; thunk++, othunk++) {
            char *name;
            DWORD old;
            if (othunk->u1.Ordinal & IMAGE_ORDINAL_FLAG)
                continue;
            name = (char *)(base + othunk->u1.AddressOfData + 2);
            if (lstrcmpA(name, fn_name) != 0) continue;
            if ((void *)thunk->u1.Function != (void *)hook) {
                if (!VirtualProtect(&thunk->u1.Function, sizeof(void *), PAGE_READWRITE, &old))
                    continue;
                thunk->u1.Function = (ULONG_PTR)hook;
                VirtualProtect(&thunk->u1.Function, sizeof(void *), old, &old);
                patched++;
            }
        }
    }
    return patched;
}

static void handle_login_src(HDC hdcSrc, int sw, int sh, const char *api, LONG n)
{
    unsigned snz = 0, snz_dib = 0;
    char spath[MAX_PATH], dibpath[MAX_PATH], json[256];
    if (!(n == 1 || n == 4 || n == 16)) return;
    snprintf(spath, sizeof(spath), "C:\\windows\\temp\\fly-stretch-src-%ld.bgra", (long)n);
    snprintf(dibpath, sizeof(dibpath), "C:\\windows\\temp\\fly-stretch-src-dib-%ld.bgra", (long)n);
    if (dump_selected_dib(hdcSrc, sw, sh, dibpath, &snz_dib) == 0)
        spy_log("  SRC GetDIBits nonzero_rgb=%u via %s\n", snz_dib, api);
    if (snz_dib == 0 && dump_hdc_bgra(hdcSrc, sw, sh, spath, &snz) == 0)
        spy_log("  SRC BitBlt nonzero_rgb=%u via %s\n", snz, api);
    else
        snz = snz_dib;
    if (snz_dib >= snz)
        maybe_bridge_copy(dibpath, snz_dib);
    else
        maybe_bridge_copy(spath, snz);
    snprintf(json, sizeof(json),
             "{\"n\":%ld,\"api\":\"%s\",\"srcNz\":%u,\"srcNzDib\":%u}",
             (long)n, api, snz, snz_dib);
    agent_log("A", "blit pixel dump post", json);
}

static BOOL WINAPI hooked_BitBlt(HDC hdcDst, int xDst, int yDst, int w, int h,
                                 HDC hdcSrc, int xSrc, int ySrc, DWORD rop)
{
    BOOL ret;
    if (InterlockedCompareExchange(&in_hook, 1, 0) != 0)
        return real_BitBlt(hdcDst, xDst, yDst, w, h, hdcSrc, xSrc, ySrc, rop);
    ret = real_BitBlt(hdcDst, xDst, yDst, w, h, hdcSrc, xSrc, ySrc, rop);
    if ((w >= 1400 && h >= 900) && login_logs < 64) {
        LONG n = InterlockedIncrement(&login_logs);
        spy_log("LOGIN_BITBLT #%ld ret=%d %dx%d\n", (long)n, (int)ret, w, h);
        agent_log("G", "login BitBlt", "{\"ok\":1}");
        handle_login_src(hdcSrc, w, h, "BitBlt", n);
    }
    InterlockedExchange(&in_hook, 0);
    return ret;
}

static int WINAPI hooked_StretchDIBits(HDC hdc, int xDst, int yDst, int wDst, int hDst,
                                       int xSrc, int ySrc, int wSrc, int hSrc,
                                       const void *bits, const BITMAPINFO *bmi,
                                       UINT usage, DWORD rop)
{
    int ret;
    int interesting;
    if (InterlockedCompareExchange(&in_hook, 1, 0) != 0)
        return real_StretchDIBits(hdc, xDst, yDst, wDst, hDst, xSrc, ySrc, wSrc, hSrc,
                                  bits, bmi, usage, rop);
    ret = real_StretchDIBits(hdc, xDst, yDst, wDst, hDst, xSrc, ySrc, wSrc, hSrc,
                             bits, bmi, usage, rop);
    interesting = (wDst >= 1400 && hDst >= 900) || (wSrc >= 1400 && hSrc >= 900);
    if (interesting && login_logs < 64) {
        LONG n = InterlockedIncrement(&login_logs);
        unsigned nz = 0;
        int w = wSrc > 0 ? wSrc : wDst;
        int h = hSrc > 0 ? hSrc : hDst;
        spy_log("LOGIN_STRETCHDIB #%ld ret=%d dst=%dx%d src=%dx%d bits=%p\n",
                (long)n, ret, wDst, hDst, wSrc, hSrc, bits);
        agent_log("G", "login StretchDIBits", "{\"ok\":1}");
        /* Direct pixel capture from DIB bits when 32bpp. */
        if (bits && bmi && bmi->bmiHeader.biBitCount == 32 && w > 8 && h > 8) {
            FILE *f;
            DWORD *p = (DWORD *)bits;
            int i, npx = w * h;
            char path[MAX_PATH];
            for (i = 0; i < npx; i++)
                if (p[i] & 0x00FFFFFF) nz++;
            snprintf(path, sizeof(path), "C:\\windows\\temp\\fly-stretch-src-dibits-%ld.bgra", (long)n);
            f = fopen(path, "wb");
            if (f) {
                fwrite(&w, 4, 1, f);
                fwrite(&h, 4, 1, f);
                fwrite(bits, 4, (size_t)npx, f);
                fclose(f);
                spy_log("  SRC StretchDIBits nonzero_rgb=%u\n", nz);
                maybe_bridge_copy(path, nz);
            }
        } else {
            handle_login_src(hdc, w, h, "StretchDIBits", n);
        }
    }
    InterlockedExchange(&in_hook, 0);
    return ret;
}

static int install_hooks(void)
{
    HMODULE gdi;
    int total = 0, delay = 0;
    HANDLE snap;
    MODULEENTRY32 me;

    gdi = GetModuleHandleA("gdi32.dll");
    if (!gdi) gdi = LoadLibraryA("gdi32.dll");
    if (!gdi) return -1;
    real_StretchBlt = (StretchBlt_fn)GetProcAddress(gdi, "StretchBlt");
    real_BitBlt = (BitBlt_fn)GetProcAddress(gdi, "BitBlt");
    real_StretchDIBits = (StretchDIBits_fn)GetProcAddress(gdi, "StretchDIBits");
    if (!real_StretchBlt) return -2;

    snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, GetCurrentProcessId());
    me.dwSize = sizeof(me);
    if (snap != INVALID_HANDLE_VALUE && Module32First(snap, &me)) {
        do {
            total += patch_iat_module(me.hModule, (void *)real_StretchBlt, (void *)hooked_StretchBlt);
            if (real_BitBlt)
                total += patch_iat_module(me.hModule, (void *)real_BitBlt, (void *)hooked_BitBlt);
            if (real_StretchDIBits)
                total += patch_iat_module(me.hModule, (void *)real_StretchDIBits, (void *)hooked_StretchDIBits);
            delay += patch_delay_iat_named(me.hModule, "StretchBlt", (void *)hooked_StretchBlt);
            delay += patch_delay_iat_named(me.hModule, "BitBlt", (void *)hooked_BitBlt);
            delay += patch_delay_iat_named(me.hModule, "StretchDIBits", (void *)hooked_StretchDIBits);
        } while (Module32Next(snap, &me));
        CloseHandle(snap);
    }
    total += patch_iat_module(GetModuleHandleA(NULL), (void *)real_StretchBlt, (void *)hooked_StretchBlt);
    delay += patch_delay_iat_named(GetModuleHandleA(NULL), "StretchBlt", (void *)hooked_StretchBlt);
    delay += patch_delay_iat_named(GetModuleHandleA(NULL), "BitBlt", (void *)hooked_BitBlt);
    delay += patch_delay_iat_named(GetModuleHandleA(NULL), "StretchDIBits", (void *)hooked_StretchDIBits);

    spy_log("IAT blit hooks: iat=%d delay=%d stretch=%p bitblt=%p dib=%p\n",
            total, delay, (void *)real_StretchBlt, (void *)real_BitBlt, (void *)real_StretchDIBits);
    {
        char json[160];
        snprintf(json, sizeof(json), "{\"iat\":%d,\"delay\":%d,\"bitblt\":%d,\"dib\":%d}",
                 total, delay, real_BitBlt ? 1 : 0, real_StretchDIBits ? 1 : 0);
        agent_log("G", "IAT hooks", json);
    }
    return (total + delay) > 0 ? 0 : -3;
}

static DWORD WINAPI rehook_thread(LPVOID arg)
{
    /* Sparse rehooks only — hammering VirtualProtect during CEF init is unsafe. */
    const DWORD delays_ms[] = { 500, 2000, 5000, 15000, 30000 };
    int i;
    (void)arg;
    for (i = 0; i < (int)(sizeof(delays_ms) / sizeof(delays_ms[0])); i++) {
        Sleep(delays_ms[i]);
        install_hooks();
    }
    return 0;
}

__declspec(dllexport) void CALLBACK FlySpyInit(HWND hwnd, HINSTANCE hinst, LPSTR cmd, int show)
{
    (void)hwnd; (void)hinst; (void)cmd; (void)show;
    install_hooks();
}

BOOL WINAPI DllMain(HINSTANCE hinst, DWORD reason, LPVOID reserved)
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(hinst);
        log_mu = CreateMutexA(NULL, FALSE, NULL);
        strcpy(log_path, "C:\\windows\\temp\\present-stretch-spy.log");
        strcpy(bgra_path, "C:\\windows\\temp\\fly-stretch-bridge.bgra");
        spy_log("DllMain attach\n");
        agent_log("C", "DllMain attach", "{\"ok\":1}");
        install_hooks();
        CreateThread(NULL, 0, rehook_thread, NULL, 0, NULL);
    }
    return TRUE;
}
