/*
 * Fly UplayWebCore shim — same pattern as steamwebhelper_shim.c.
 *
 * Ubisoft Connect parent (upc.exe) does not forward CLI CEF flags to
 * UplayWebCore children. Wrap UplayWebCore.exe → UplayWebCore_real.exe and
 * inject software-compositing flags so Wine/macOS can paint the login UI
 * (native CEF shared-texture path leaves a transparent frame).
 *
 * Override order:
 *   1) FLY_CEF_FLAGS / AETHER_CEF_FLAGS env
 *   2) sibling webcore_args.txt (one flag per line, # comments ok)
 *   3) safe default: in-process-gpu + ANGLE SwiftShader + no GPU compositing
 *      (NEVER --disable-gpu — alpha-0 / HWND death under modern Connect).
 */
#include <stdio.h>
#include <string.h>
#include <windows.h>

static int read_args_file(const WCHAR *dir, WCHAR *out, DWORD outChars) {
    WCHAR path[MAX_PATH];
    wcscpy(path, dir);
    wcscat(path, L"webcore_args.txt");
    FILE *f = _wfopen(path, L"r");
    if (!f)
        return 0;
    out[0] = L'\0';
    char line[512];
    while (fgets(line, sizeof(line), f)) {
        char *p = line;
        while (*p == ' ' || *p == '\t')
            p++;
        if (*p == '#' || *p == '\n' || *p == '\r' || !*p)
            continue;
        size_t n = strlen(p);
        while (n && (p[n - 1] == '\n' || p[n - 1] == '\r' || p[n - 1] == ' '))
            p[--n] = '\0';
        if (!n)
            continue;
        if (out[0])
            wcsncat(out, L" ", outChars - (DWORD)wcslen(out) - 1);
        WCHAR wline[512];
        MultiByteToWideChar(CP_UTF8, 0, p, -1, wline, 512);
        wcsncat(out, wline, outChars - (DWORD)wcslen(out) - 1);
    }
    fclose(f);
    return out[0] != L'\0';
}

int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE hPrev, LPSTR lpCmdLine, int nCmdShow) {
    (void)hInstance;
    (void)hPrev;
    (void)lpCmdLine;
    (void)nCmdShow;

    WCHAR myPath[MAX_PATH];
    if (!GetModuleFileNameW(NULL, myPath, MAX_PATH))
        return 1;

    WCHAR *lastSlash = wcsrchr(myPath, L'\\');
    if (!lastSlash)
        return 1;
    *(lastSlash + 1) = L'\0';

    WCHAR realExe[MAX_PATH];
    wcscpy(realExe, myPath);
    wcscat(realExe, L"UplayWebCore_real.exe");

    LPWSTR origCmd = GetCommandLineW();
    LPWSTR args = origCmd;
    if (*args == L'"') {
        args++;
        while (*args && *args != L'"')
            args++;
        if (*args == L'"')
            args++;
    } else {
        while (*args && *args != L' ')
            args++;
    }

    WCHAR flags[4096];
    DWORD flagLen = GetEnvironmentVariableW(L"FLY_CEF_FLAGS", flags, 4096);
    if (flagLen == 0 || flagLen >= 4096)
        flagLen = GetEnvironmentVariableW(L"AETHER_CEF_FLAGS", flags, 4096);
    if (flagLen == 0 || flagLen >= 4096) {
        if (read_args_file(myPath, flags, 4096))
            flagLen = (DWORD)wcslen(flags);
        else
            flagLen = 0;
    }

    WCHAR newCmd[32768];
    wcscpy(newCmd, L"\"");
    wcscat(newCmd, realExe);
    wcscat(newCmd, L"\" ");
    if (flagLen > 0 && flagLen < 4096)
        wcscat(newCmd, flags);
    else
        /* Keep GPU process alive; ANGLE+SwiftShader; NEVER --disable-gpu
         * (--disable-gpu → ULW layered surfaces with alpha=0 → invisible). */
        wcscat(newCmd,
               L"--no-sandbox --in-process-gpu --use-gl=angle "
               L"--use-angle=swiftshader-webgl --disable-gpu-compositing");
    if (*args)
        wcscat(newCmd, args);

    STARTUPINFOW si;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    PROCESS_INFORMATION pi;
    ZeroMemory(&pi, sizeof(pi));

    if (!CreateProcessW(realExe, newCmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi))
        return 1;

    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD exitCode = 0;
    GetExitCodeProcess(pi.hProcess, &exitCode);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return (int)exitCode;
}
