/*
 * version_proxy.c — app-dir VERSION.dll that loads present_stretch_spy.dll.
 * Implements real stubs that call into sibling version_wine.dll (NOT PE
 * forwarders — Wine skips DllMain on forwarder-only PEs).
 *
 *   i686-w64-mingw32-gcc -shared -O2 -mwindows -o Tools/bin/version.dll \
 *       Tools/version_proxy.c Tools/version_proxy.def \
 *       -Wl,--kill-at -Wl,--enable-stdcall-fix
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <string.h>

static HMODULE real_ver;
static HMODULE spy;
static char dir_path[MAX_PATH];

typedef DWORD (WINAPI *t_GetFileVersionInfoSizeA)(LPCSTR, LPDWORD);
typedef DWORD (WINAPI *t_GetFileVersionInfoSizeW)(LPCWSTR, LPDWORD);
typedef BOOL (WINAPI *t_GetFileVersionInfoA)(LPCSTR, DWORD, DWORD, LPVOID);
typedef BOOL (WINAPI *t_GetFileVersionInfoW)(LPCWSTR, DWORD, DWORD, LPVOID);
typedef BOOL (WINAPI *t_VerQueryValueA)(LPCVOID, LPCSTR, LPVOID *, PUINT);
typedef BOOL (WINAPI *t_VerQueryValueW)(LPCVOID, LPCWSTR, LPVOID *, PUINT);
typedef DWORD (WINAPI *t_GetFileVersionInfoSizeExA)(DWORD, LPCSTR, LPDWORD);
typedef DWORD (WINAPI *t_GetFileVersionInfoSizeExW)(DWORD, LPCWSTR, LPDWORD);
typedef BOOL (WINAPI *t_GetFileVersionInfoExA)(DWORD, LPCSTR, DWORD, DWORD, LPVOID);
typedef BOOL (WINAPI *t_GetFileVersionInfoExW)(DWORD, LPCWSTR, DWORD, DWORD, LPVOID);
typedef DWORD (WINAPI *t_VerFindFileA)(DWORD, LPSTR, LPSTR, LPSTR, LPSTR, PUINT, LPSTR, PUINT);
typedef DWORD (WINAPI *t_VerFindFileW)(DWORD, LPWSTR, LPWSTR, LPWSTR, LPWSTR, PUINT, LPWSTR, PUINT);
typedef DWORD (WINAPI *t_VerInstallFileA)(DWORD, LPSTR, LPSTR, LPSTR, LPSTR, LPSTR, LPSTR, PUINT);
typedef DWORD (WINAPI *t_VerInstallFileW)(DWORD, LPWSTR, LPWSTR, LPWSTR, LPWSTR, LPWSTR, LPWSTR, PUINT);
typedef DWORD (WINAPI *t_VerLanguageNameA)(DWORD, LPSTR, DWORD);
typedef DWORD (WINAPI *t_VerLanguageNameW)(DWORD, LPWSTR, DWORD);

static t_GetFileVersionInfoSizeA p_GetFileVersionInfoSizeA;
static t_GetFileVersionInfoSizeW p_GetFileVersionInfoSizeW;
static t_GetFileVersionInfoA p_GetFileVersionInfoA;
static t_GetFileVersionInfoW p_GetFileVersionInfoW;
static t_VerQueryValueA p_VerQueryValueA;
static t_VerQueryValueW p_VerQueryValueW;
static t_GetFileVersionInfoSizeExA p_GetFileVersionInfoSizeExA;
static t_GetFileVersionInfoSizeExW p_GetFileVersionInfoSizeExW;
static t_GetFileVersionInfoExA p_GetFileVersionInfoExA;
static t_GetFileVersionInfoExW p_GetFileVersionInfoExW;
static t_VerFindFileA p_VerFindFileA;
static t_VerFindFileW p_VerFindFileW;
static t_VerInstallFileA p_VerInstallFileA;
static t_VerInstallFileW p_VerInstallFileW;
static t_VerLanguageNameA p_VerLanguageNameA;
static t_VerLanguageNameW p_VerLanguageNameW;

__declspec(dllexport) DWORD WINAPI GetFileVersionInfoSizeA(LPCSTR a, LPDWORD b)
{ return p_GetFileVersionInfoSizeA ? p_GetFileVersionInfoSizeA(a, b) : 0; }
__declspec(dllexport) DWORD WINAPI GetFileVersionInfoSizeW(LPCWSTR a, LPDWORD b)
{ return p_GetFileVersionInfoSizeW ? p_GetFileVersionInfoSizeW(a, b) : 0; }
__declspec(dllexport) BOOL WINAPI GetFileVersionInfoA(LPCSTR a, DWORD b, DWORD c, LPVOID d)
{ return p_GetFileVersionInfoA ? p_GetFileVersionInfoA(a, b, c, d) : FALSE; }
__declspec(dllexport) BOOL WINAPI GetFileVersionInfoW(LPCWSTR a, DWORD b, DWORD c, LPVOID d)
{ return p_GetFileVersionInfoW ? p_GetFileVersionInfoW(a, b, c, d) : FALSE; }
__declspec(dllexport) BOOL WINAPI VerQueryValueA(LPCVOID a, LPCSTR b, LPVOID *c, PUINT d)
{ return p_VerQueryValueA ? p_VerQueryValueA(a, b, c, d) : FALSE; }
__declspec(dllexport) BOOL WINAPI VerQueryValueW(LPCVOID a, LPCWSTR b, LPVOID *c, PUINT d)
{ return p_VerQueryValueW ? p_VerQueryValueW(a, b, c, d) : FALSE; }
__declspec(dllexport) DWORD WINAPI GetFileVersionInfoSizeExA(DWORD f, LPCSTR a, LPDWORD b)
{ return p_GetFileVersionInfoSizeExA ? p_GetFileVersionInfoSizeExA(f, a, b) : 0; }
__declspec(dllexport) DWORD WINAPI GetFileVersionInfoSizeExW(DWORD f, LPCWSTR a, LPDWORD b)
{ return p_GetFileVersionInfoSizeExW ? p_GetFileVersionInfoSizeExW(f, a, b) : 0; }
__declspec(dllexport) BOOL WINAPI GetFileVersionInfoExA(DWORD f, LPCSTR a, DWORD b, DWORD c, LPVOID d)
{ return p_GetFileVersionInfoExA ? p_GetFileVersionInfoExA(f, a, b, c, d) : FALSE; }
__declspec(dllexport) BOOL WINAPI GetFileVersionInfoExW(DWORD f, LPCWSTR a, DWORD b, DWORD c, LPVOID d)
{ return p_GetFileVersionInfoExW ? p_GetFileVersionInfoExW(f, a, b, c, d) : FALSE; }
__declspec(dllexport) DWORD WINAPI VerFindFileA(DWORD a, LPSTR b, LPSTR c, LPSTR d, LPSTR e, PUINT f, LPSTR g, PUINT h)
{ return p_VerFindFileA ? p_VerFindFileA(a, b, c, d, e, f, g, h) : 0; }
__declspec(dllexport) DWORD WINAPI VerFindFileW(DWORD a, LPWSTR b, LPWSTR c, LPWSTR d, LPWSTR e, PUINT f, LPWSTR g, PUINT h)
{ return p_VerFindFileW ? p_VerFindFileW(a, b, c, d, e, f, g, h) : 0; }
__declspec(dllexport) DWORD WINAPI VerInstallFileA(DWORD a, LPSTR b, LPSTR c, LPSTR d, LPSTR e, LPSTR f, LPSTR g, PUINT h)
{ return p_VerInstallFileA ? p_VerInstallFileA(a, b, c, d, e, f, g, h) : 0; }
__declspec(dllexport) DWORD WINAPI VerInstallFileW(DWORD a, LPWSTR b, LPWSTR c, LPWSTR d, LPWSTR e, LPWSTR f, LPWSTR g, PUINT h)
{ return p_VerInstallFileW ? p_VerInstallFileW(a, b, c, d, e, f, g, h) : 0; }
__declspec(dllexport) DWORD WINAPI VerLanguageNameA(DWORD a, LPSTR b, DWORD c)
{ return p_VerLanguageNameA ? p_VerLanguageNameA(a, b, c) : 0; }
__declspec(dllexport) DWORD WINAPI VerLanguageNameW(DWORD a, LPWSTR b, DWORD c)
{ return p_VerLanguageNameW ? p_VerLanguageNameW(a, b, c) : 0; }

static void breadcrumb(const char *msg)
{
    HANDLE h = CreateFileA("C:\\windows\\temp\\version-proxy.log",
                           FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
                           NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h != INVALID_HANDLE_VALUE) {
        DWORD w;
        WriteFile(h, msg, (DWORD)lstrlenA(msg), &w, NULL);
        WriteFile(h, "\r\n", 2, &w, NULL);
        CloseHandle(h);
    }
}

/* #region agent log */
static void agent_log(const char *hid, const char *msg, const char *data_json)
{
    FILE *f = fopen("C:\\windows\\temp\\debug-505da6.log", "a");
    if (!f)
        f = fopen("Z:\\Users\\ebenoelofse\\Desktop\\Fly\\.cursor\\debug-505da6.log", "a");
    if (f) {
        fprintf(f,
                "{\"sessionId\":\"505da6\",\"hypothesisId\":\"%s\",\"location\":\"version.dll\","
                "\"message\":\"%s\",\"data\":%s,\"timestamp\":%lu}\n",
                hid, msg, data_json ? data_json : "{}", (unsigned long)GetTickCount());
        fclose(f);
    }
}
/* #endregion */

static void load_real(void)
{
    char path[MAX_PATH];
    lstrcpyA(path, dir_path);
    lstrcatA(path, "version_wine.dll");
    real_ver = LoadLibraryA(path);
    if (!real_ver) {
        breadcrumb("load_real FAIL");
        return;
    }
    breadcrumb("load_real OK");
    p_GetFileVersionInfoSizeA = (t_GetFileVersionInfoSizeA)GetProcAddress(real_ver, "GetFileVersionInfoSizeA");
    p_GetFileVersionInfoSizeW = (t_GetFileVersionInfoSizeW)GetProcAddress(real_ver, "GetFileVersionInfoSizeW");
    p_GetFileVersionInfoA = (t_GetFileVersionInfoA)GetProcAddress(real_ver, "GetFileVersionInfoA");
    p_GetFileVersionInfoW = (t_GetFileVersionInfoW)GetProcAddress(real_ver, "GetFileVersionInfoW");
    p_VerQueryValueA = (t_VerQueryValueA)GetProcAddress(real_ver, "VerQueryValueA");
    p_VerQueryValueW = (t_VerQueryValueW)GetProcAddress(real_ver, "VerQueryValueW");
    p_GetFileVersionInfoSizeExA = (t_GetFileVersionInfoSizeExA)GetProcAddress(real_ver, "GetFileVersionInfoSizeExA");
    p_GetFileVersionInfoSizeExW = (t_GetFileVersionInfoSizeExW)GetProcAddress(real_ver, "GetFileVersionInfoSizeExW");
    p_GetFileVersionInfoExA = (t_GetFileVersionInfoExA)GetProcAddress(real_ver, "GetFileVersionInfoExA");
    p_GetFileVersionInfoExW = (t_GetFileVersionInfoExW)GetProcAddress(real_ver, "GetFileVersionInfoExW");
    p_VerFindFileA = (t_VerFindFileA)GetProcAddress(real_ver, "VerFindFileA");
    p_VerFindFileW = (t_VerFindFileW)GetProcAddress(real_ver, "VerFindFileW");
    p_VerInstallFileA = (t_VerInstallFileA)GetProcAddress(real_ver, "VerInstallFileA");
    p_VerInstallFileW = (t_VerInstallFileW)GetProcAddress(real_ver, "VerInstallFileW");
    p_VerLanguageNameA = (t_VerLanguageNameA)GetProcAddress(real_ver, "VerLanguageNameA");
    p_VerLanguageNameW = (t_VerLanguageNameW)GetProcAddress(real_ver, "VerLanguageNameW");
}

static DWORD WINAPI load_spy_thread(LPVOID arg)
{
    char path[MAX_PATH];
    char json[160];
    (void)arg;
    Sleep(50);
    lstrcpyA(path, dir_path);
    lstrcatA(path, "present_stretch_spy.dll");
    spy = LoadLibraryA(path);
    if (!spy)
        spy = LoadLibraryA("present_stretch_spy.dll");
    snprintf(json, sizeof(json), "{\"spy\":\"%p\",\"err\":%lu}",
             (void *)spy, (unsigned long)GetLastError());
    agent_log("C", "deferred spy load", json);
    breadcrumb(json);
    return 0;
}

BOOL WINAPI DllMain(HINSTANCE hinst, DWORD reason, LPVOID reserved)
{
    char *slash;
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(hinst);
        breadcrumb("DllMain PROCESS_ATTACH");
        dir_path[0] = '\0';
        if (GetModuleFileNameA(hinst, dir_path, MAX_PATH)) {
            slash = strrchr(dir_path, '\\');
            if (slash) slash[1] = '\0';
        }
        /* Load version_wine under lock — same-dir rename, not system32 recurse. */
        load_real();
        agent_log("C", "version DllMain attach", "{\"ok\":1}");
        CreateThread(NULL, 0, load_spy_thread, NULL, 0, NULL);
    } else if (reason == DLL_PROCESS_DETACH) {
        if (spy) FreeLibrary(spy);
        if (real_ver) FreeLibrary(real_ver);
    }
    return TRUE;
}
