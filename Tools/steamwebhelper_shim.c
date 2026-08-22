/*
 * Fly steamwebhelper shim — based on wisnuub/Steam-Win-Silicon + notpop/steam-on-m1-wine.
 *
 * Wine on Apple Silicon fails CEF cross-process frame present (black UI window).
 * Inject --disable-gpu --single-process so CEF stays single-process / software UI.
 * Games are unaffected (separate processes).
 *
 * Override flags with FLY_CEF_FLAGS (or AETHER_CEF_FLAGS for compatibility).
 */
#include <windows.h>

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
    wcscat(realExe, L"steamwebhelper_real.exe");

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

    WCHAR newCmd[32768];
    wcscpy(newCmd, L"\"");
    wcscat(newCmd, realExe);
    wcscat(newCmd, L"\" ");
    if (flagLen > 0 && flagLen < 4096)
        wcscat(newCmd, flags);
    else
        /* GPTK/Wine: --single-process often deadlocks (RtlWaitForCriticalSection /
         * "steamwebhelper is not responding"). Prefer disable-gpu + in-process GPU.
         * Override with FLY_CEF_FLAGS if needed. */
        wcscat(newCmd, L"--disable-gpu --in-process-gpu");
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
