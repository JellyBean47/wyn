/* %gs probe for scripts/smoke-runtime.sh: where %gs points while Windows code
 * runs (ntdll's per-process model, patches/winecx/0001), and whether
 * GetCurrentFiber(), which MSVC inlines as a gs:[0x20] read, finds the fiber.
 *
 * gs:[0x08] is NT_TIB.StackBase in a TEB and errno in a macOS TSD. Both models
 * keep the TEB's own address at gs:[0x30], so comparing the two tells them
 * apart. DOOM (2016) stopped at 91% because GetCurrentFiber() returned the
 * TSD's QoS class, 0x8ff, and the game switched to it. */
#include <windows.h>
#include <stdio.h>
#include <intrin.h>

static const char *gs_base(void)
{
    NT_TIB *tib = (NT_TIB *)__readgsqword(0x30);
    return (void *)__readgsqword(0x08) == tib->StackBase ? "TEB" : "TSD";
}

static DWORD WINAPI worker(void *arg)
{
    printf("worker gs=%s\n", gs_base());
    return 0;
}

int main(void)
{
    HANDLE thread;
    void *fiber;

    printf("main gs=%s\n", gs_base());
    thread = CreateThread(NULL, 0, worker, NULL, 0, NULL);
    WaitForSingleObject(thread, INFINITE);
    fiber = ConvertThreadToFiber(NULL);
    printf("fiber %s: ConvertThreadToFiber=%p gs:[0x20]=%p\n",
           fiber && (void *)__readgsqword(0x20) == fiber ? "ok" : "WRONG",
           fiber, (void *)__readgsqword(0x20));
    fflush(stdout);
    return 0;
}
