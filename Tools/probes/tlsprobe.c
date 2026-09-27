/* HTTPS through WinHTTP: schannel (secur32 -> GnuTLS) for the handshake and
 * crypt32 (macOS keychain roots) for the chain. The same path Steam's login
 * and a game's own HTTPS take. */
#include <windows.h>
#include <winhttp.h>
#include <schannel.h>
#include <stdio.h>

static int probe(const wchar_t *host)
{
    HINTERNET s = WinHttpOpen(L"WynTLSProbe/1.0", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, NULL, NULL, 0);
    HINTERNET c = s ? WinHttpConnect(s, host, INTERNET_DEFAULT_HTTPS_PORT, 0) : NULL;
    HINTERNET r = c ? WinHttpOpenRequest(c, L"HEAD", L"/", NULL, NULL, NULL, WINHTTP_FLAG_SECURE) : NULL;
    BOOL ok = r && WinHttpSendRequest(r, NULL, 0, NULL, 0, 0, 0) && WinHttpReceiveResponse(r, NULL);
    DWORD err = ok ? 0 : GetLastError(), status = 0, len = sizeof(status);
    if (ok)
        WinHttpQueryHeaders(r, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, NULL, &status, &len, NULL);
    printf("https://%ls/: %s status=%lu error=%lu\n", host, ok ? "ok" : "FAIL", status, err);
    if (r) WinHttpCloseHandle(r);
    if (c) WinHttpCloseHandle(c);
    if (s) WinHttpCloseHandle(s);
    return !ok;
}

int main(void)
{
    int failed = probe(L"store.steampowered.com");
    failed |= probe(L"www.winehq.org");
    fflush(stdout);
    return failed;
}
