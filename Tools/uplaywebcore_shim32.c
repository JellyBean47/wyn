/*
 * uplaywebcore_shim32.c — PE32 shim matching UplayWebCore.exe arch.
 * Injects present_stretch_spy.dll into the real WebCore child (CREATE_SUSPENDED).
 *
 *   i686-w64-mingw32-gcc -O2 -o Tools/bin/uplaywebcore_shim32.exe \
 *       Tools/uplaywebcore_shim32.c -lkernel32
 */
#include <stdio.h>
#include <string.h>
#include <windows.h>

static int read_args_file(const WCHAR *dir, WCHAR *out, DWORD outChars)
{
    WCHAR path[MAX_PATH];
    FILE *f;
    char line[512];
    wcscpy(path, dir);
    wcscat(path, L"webcore_args.txt");
    f = _wfopen(path, L"r");
    if (!f) return 0;
    out[0] = L'\0';
    while (fgets(line, sizeof(line), f)) {
        char *p = line;
        size_t n;
        WCHAR wline[512];
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '#' || *p == '\n' || *p == '\r' || !*p) continue;
        n = strlen(p);
        while (n && (p[n - 1] == '\n' || p[n - 1] == '\r' || p[n - 1] == ' '))
            p[--n] = '\0';
        if (!n) continue;
        if (out[0])
            wcsncat(out, L" ", outChars - (DWORD)wcslen(out) - 1);
        MultiByteToWideChar(CP_UTF8, 0, p, -1, wline, 512);
        wcsncat(out, wline, outChars - (DWORD)wcslen(out) - 1);
    }
    fclose(f);
    return out[0] != L'\0';
}

static void shim_log(const char *msg)
{
    HANDLE h = CreateFileA("C:\\windows\\temp\\webcore-shim.log",
                           FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
                           NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h != INVALID_HANDLE_VALUE) {
        DWORD w;
        WriteFile(h, msg, (DWORD)lstrlenA(msg), &w, NULL);
        WriteFile(h, "\r\n", 2, &w, NULL);
        CloseHandle(h);
    }
}

static int inject_dll(HANDLE proc, const WCHAR *dllPath)
{
    SIZE_T bytes = (wcslen(dllPath) + 1) * sizeof(WCHAR);
    void *remote;
    HANDLE thread;
    FARPROC loadLib;
    DWORD tid = 0;
    char buf[256];

    loadLib = GetProcAddress(GetModuleHandleA("kernel32.dll"), "LoadLibraryW");
    if (!loadLib) { shim_log("inject: no LoadLibraryW"); return 0; }
    remote = VirtualAllocEx(proc, NULL, bytes, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!remote) { shim_log("inject: VirtualAllocEx fail"); return 0; }
    if (!WriteProcessMemory(proc, remote, dllPath, bytes, NULL)) {
        VirtualFreeEx(proc, remote, 0, MEM_RELEASE);
        shim_log("inject: WriteProcessMemory fail");
        return 0;
    }
    /* Small delay so the child finishes early loader work before remote LoadLibrary. */
    Sleep(100);
    thread = CreateRemoteThread(proc, NULL, 0, (LPTHREAD_START_ROUTINE)loadLib, remote, 0, &tid);
    if (!thread) {
        VirtualFreeEx(proc, remote, 0, MEM_RELEASE);
        shim_log("inject: CreateRemoteThread fail");
        return 0;
    }
    WaitForSingleObject(thread, 5000);
    CloseHandle(thread);
    wsprintfA(buf, "inject: ok tid=%lu", (unsigned long)tid);
    shim_log(buf);
    return 1;
}

int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE hPrev, LPSTR lpCmdLine, int nCmdShow)
{
    WCHAR myPath[MAX_PATH], realExe[MAX_PATH], spyDll[MAX_PATH], flags[4096], newCmd[32768];
    WCHAR *lastSlash;
    LPWSTR origCmd, args;
    DWORD flagLen;
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;

    (void)hInstance; (void)hPrev; (void)lpCmdLine; (void)nCmdShow;

    if (!GetModuleFileNameW(NULL, myPath, MAX_PATH)) return 1;
    lastSlash = wcsrchr(myPath, L'\\');
    if (!lastSlash) return 1;
    *(lastSlash + 1) = L'\0';

    wcscpy(realExe, myPath);
    wcscat(realExe, L"UplayWebCore_real.exe");
    wcscpy(spyDll, myPath);
    wcscat(spyDll, L"present_stretch_spy.dll");

    origCmd = GetCommandLineW();
    args = origCmd;
    if (*args == L'"') {
        args++;
        while (*args && *args != L'"') args++;
        if (*args == L'"') args++;
    } else {
        while (*args && *args != L' ') args++;
    }

    /* CEF child processes: forward to real. Only inject spy into renderer/gpu
     * (StretchBlt path); skip utility/storage to avoid startup stalls. */
    if (wcsstr(origCmd, L"--type=")) {
        int do_inject = 0;
        if (wcsstr(origCmd, L"--type=renderer") || wcsstr(origCmd, L"--type=gpu"))
            do_inject = 1;
        ZeroMemory(&si, sizeof(si));
        si.cb = sizeof(si);
        ZeroMemory(&pi, sizeof(pi));
        wcscpy(newCmd, L"\"");
        wcscat(newCmd, realExe);
        wcscat(newCmd, L"\"");
        wcscat(newCmd, args);
        if (!CreateProcessW(realExe, newCmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi))
            return 1;
        if (do_inject && GetFileAttributesW(spyDll) != INVALID_FILE_ATTRIBUTES)
            inject_dll(pi.hProcess, spyDll);
        WaitForSingleObject(pi.hProcess, INFINITE);
        {
            DWORD exitCode = 0;
            GetExitCodeProcess(pi.hProcess, &exitCode);
            CloseHandle(pi.hProcess);
            CloseHandle(pi.hThread);
            return (int)exitCode;
        }
    }

    flagLen = GetEnvironmentVariableW(L"FLY_CEF_FLAGS", flags, 4096);
    if (flagLen == 0 || flagLen >= 4096)
        flagLen = GetEnvironmentVariableW(L"AETHER_CEF_FLAGS", flags, 4096);
    if (flagLen == 0 || flagLen >= 4096) {
        if (read_args_file(myPath, flags, 4096))
            flagLen = (DWORD)wcslen(flags);
        else
            flagLen = 0;
    }

    wcscpy(newCmd, L"\"");
    wcscat(newCmd, realExe);
    wcscat(newCmd, L"\" ");
    if (flagLen > 0 && flagLen < 4096)
        wcscat(newCmd, flags);
    else
        wcscat(newCmd,
               L"--no-sandbox --in-process-gpu --use-gl=angle "
               L"--use-angle=swiftshader-webgl --disable-gpu-compositing");
    if (*args)
        wcscat(newCmd, args);

    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));

    if (!CreateProcessW(realExe, newCmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi))
        return 1;

    /* Inject into running process — NEVER LoadLibrary while suspended (loader lock). */
    if (GetFileAttributesW(spyDll) != INVALID_FILE_ATTRIBUTES)
        inject_dll(pi.hProcess, spyDll);

    WaitForSingleObject(pi.hProcess, INFINITE);
    {
        DWORD exitCode = 0;
        GetExitCodeProcess(pi.hProcess, &exitCode);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
        return (int)exitCode;
    }
}
