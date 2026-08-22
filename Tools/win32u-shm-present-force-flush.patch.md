# win32u HACK 23950 — force parent present after shm flush

**Why:** Connect login StretchBlt runs in a child process; pixels cross to the parent via
`WM_WINE_FLUSHSHMSURFACE`, but the parent often never pushes them to Cocoa
(`setColorImage` never fires on the new login `WineContentView`). See HANDOFF §2.11.

**Root cause (ranked):**
1. `process_surface_message` does `SetDIBitsToDevice` (dirties surface bounds) then returns
   without flushing. dibdrv only auto-flushes after **50 ms** of drawing; a single
   SetDIBits is far shorter. Parent then depends on idle `flush_window_surfaces`, which
   may not run soon enough during CEF login.
2. `shm_surface_flush` uses `SendMessageTimeout(..., SMTO_ABORTIFHUNG|SMTO_BLOCK, 500)` —
   easy to miss under a busy parent queue.

**Apply to:** frankea / CX-foss `dlls/win32u/dce.c` (HACK 23950 block), then rebuild
`win32u.so` and replace
`Libraries.steam/Wine/lib/wine/x86_64-unix/win32u.so` (keep a `.bak`).

**Applied (9 Aug ~18:05) via reversible binary patch** (no Wine rebuild) —
`Tools/apply-win32u-shm-force-flush.py` → live frankea `win32u.so`, backup
`win32u.so.pre-force-flush.bak`. Work copies: `Tools/bin/win32u.force-flush.so`,
`Tools/bin/win32u.smto-only.so`. Re-sign adhoc after edit. Kill frankea wineserver
before replace.

```diff
--- a/dlls/win32u/dce.c
+++ b/dlls/win32u/dce.c
@@ -752,7 +752,8 @@ static BOOL shm_surface_flush( struct window_surface *window_surface, const RECT
     params.info = surface->info;
     params.bounds = *dirty;
 
-    return send_message_timeout( surface->parent, WM_WINE_FLUSHSHMSURFACE, 0, (LPARAM)&params,
-                                 SMTO_ABORTIFHUNG | SMTO_BLOCK, 500, FALSE );
+    /* Longer timeout; do not abort if parent looks "hung" (CEF often is). */
+    return send_message_timeout( surface->parent, WM_WINE_FLUSHSHMSURFACE, 0, (LPARAM)&params,
+                                 SMTO_BLOCK, 5000, FALSE );
 }
 
@@ -904,6 +905,7 @@ void process_surface_message( struct flush_shm_surface_params *params )
 {
     HANDLE mapping = LongToHandle( params->section );
     HWND hwnd = LongToHandle( params->hwnd );
     SIZE_T view_size = 0;
     unsigned int height;
     unsigned int status;
     void *bits = NULL;
     HDC hdc;
 
     TRACE( "Flushing %p window surface %s\n", hwnd, wine_dbgstr_rect( &params->bounds ));
 
     status = NtMapViewOfSection( mapping, GetCurrentProcess(), (void**)&bits,
                                  0, 0, NULL, &view_size, ViewShare, 0, PAGE_READONLY );
     if (!bits)
     {
         ERR( "NtMapViewOfSection failed: %x\n", status );
         return;
     }
     height = abs( params->info.bmiHeader.biHeight );
 
     hdc = NtUserGetDCEx( hwnd, NULL, DCX_CLIPSIBLINGS );
     NtGdiSetDIBitsToDeviceInternal( hdc, params->bounds.left, params->bounds.top,
                                     params->bounds.right - params->bounds.left, params->bounds.bottom - params->bounds.top,
                                     params->bounds.left, height - params->bounds.bottom, 0, height,
                                     bits, &params->info, DIB_RGB_COLORS, 0, 0, FALSE, NULL);
     NtUserReleaseDC( hwnd, hdc );
     NtUnmapViewOfSection( GetCurrentProcess(), bits );
+
+    /* Cross-process blit dirties the parent surface but rarely trips the 50ms
+     * dibdrv auto-flush. Push to macdrv → setColorImage immediately. */
+    flush_window_surfaces( TRUE );
 }
```

**Also apply (secondary):** `Tools/macdrv-present-opaque-alpha.patch.md`
(clear layered state on non-layered `CreateWindowSurface` + opaque-alpha OR).

**Verify:**
1. §2.8 Connect recipe; inject log-only (`PRESENT_FORCE_OPAQUE=0`).
2. After `Close for browser id: 4`, inject shows login-sized `setColorImage` and
   `updateLayer` with non-nil contents on the **new** view.
3. Login UI visible in `screencapture -l` (not ~6 KB alpha-0).

**Runtime TRACE (no rebuild):** short capture with
`WINEDEBUG=+win,+timestamp` around the splash→login transition; look for
`create_shm_surface` / `Flushing %p window surface` vs silence (SMTO miss).
Do **not** leave heavy `+bitblt` on for the full run.
