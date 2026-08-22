/* FOSS macdrv present patch sketch — for frankea/wine-11 or CX-foss rebuild.
 *
 * Problem (Fly Connect §2.9/§2.10):
 *   Splash ULW AlphaBlend → layered surface → setColorImage → updateLayer sets CALayer.contents (works).
 *   Login StretchBlt → non-layered surface; Cocoa view can resize to ~1454x934 and updateLayer
 *   with colorImage==nil → contents stay NULL → transparent interior.
 *
 * Observed (present-force inject 20260809-171345):
 *   updateLayer bounds=1454x934 contents 0x0 -> 0x0
 *   No setColorImage with login-sized CGImage in that window.
 *
 * Also: macdrv does not OR opaque alpha on non-layered flush (x11/android do).
 * CreateWindowSurface(layered=FALSE) does not clear data->layered / per-pixel state
 * (only SetWindowStyle WS_EX_LAYERED change does).
 */

## Applied levers (Fly, 9 Aug 2026) — **§2.14 FAIL/REGRESS**

1. **Binary layered-clear** via `Tools/apply-winemac-layered-clear.py` — **tried, restored**.
   Bitfield clear alone stalled StartView vs stock; stock login still wallpaper.
   Do **not** leave installed without Cocoa `sync_window_opacity`.
2. **Cocoa sync** via inject `PRESENT_FORCE_OPAQUE=1` — stalls StartView; use log-only (`=0`) for probes.
3. **Opaque-alpha OR** in `macdrv_surface_flush` still needs a **rebuild** (below);
   useless until login-sized `setColorImage` exists.

#if 0  /* apply into dlls/winemac.drv/surface.c */

/* In macdrv_CreateWindowSurface — when switching to non-layered, clear ULW state: */
BOOL macdrv_CreateWindowSurface(HWND hwnd, BOOL layered, const RECT *surface_rect,
                                struct window_surface **surface)
{
    ...
    if (layered)
    {
        data->layered = TRUE;
        data->ulw_layered = TRUE;
    }
    else if (data->layered || data->ulw_layered || data->per_pixel_alpha)
    {
        data->layered = FALSE;
        data->ulw_layered = FALSE;
        sync_window_opacity(data, 0, FALSE, 0); /* clears usePerPixelAlpha */
        /* also clear any stale shape image on the Cocoa view */
        if (data->cocoa_window)
            macdrv_window_set_shape_image(data->cocoa_window, NULL);
    }
    ...
}

/* In macdrv_surface_flush — mirror winex11 opaque-alpha OR for non-layered: */
static BOOL macdrv_surface_flush(...)
{
    ...
    if (!window_surface->alpha_mask && color_info->bmiHeader.biBitCount == 32)
    {
        /* Ensure A=0xff so Cocoa opaque present is robust if alpha mode is wrong */
        int x, y, stride = color_info->bmiHeader.biSizeImage / abs(color_info->bmiHeader.biHeight) / 4;
        ULONG *ptr = (ULONG *)color_bits + dirty->top * stride;
        for (y = dirty->top; y < dirty->bottom; y++, ptr += stride)
            for (x = dirty->left; x < dirty->right; x++)
                ptr[x] |= 0xff000000;
    }
    ...
}
#endif
