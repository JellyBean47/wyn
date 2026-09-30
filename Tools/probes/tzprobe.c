/* Time zone probe for scripts/smoke-runtime.sh: the zone Windows code is
 * told it is in, the way applications ask for it. Chromium turns this key
 * name into the IANA zone its pages report, Ubisoft Connect's bot check
 * included. Before patches/winecx/0002 a Mac in Africa/Johannesburg got
 * "Kaliningrad Standard Time". */
#define _WIN32_WINNT 0x0600
#include <windows.h>
#include <stdio.h>

int main(void)
{
    DYNAMIC_TIME_ZONE_INFORMATION tz;
    char name[256];
    if (GetDynamicTimeZoneInformation(&tz) == TIME_ZONE_ID_INVALID) {
        printf("GetDynamicTimeZoneInformation failed: %lu\n", GetLastError());
        return 1;
    }
    WideCharToMultiByte(CP_UTF8, 0, tz.TimeZoneKeyName, -1, name, sizeof(name), NULL, NULL);
    printf("zone %s\nbias %ld\n", name, tz.Bias);
    return 0;
}
