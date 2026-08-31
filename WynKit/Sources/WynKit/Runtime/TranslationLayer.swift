//
//  TranslationLayer.swift
//  WynKit
//

import Foundation

/// Direct3D → Metal translation backend selection.
public enum TranslationLayer: String, Codable, CaseIterable, Sendable {
    /// Apple Game Porting Toolkit D3DMetal (opt-in; user-supplied GPTK).
    case d3dMetal = "d3dmetal"
    /// DXVK-macOS: D3D9/10/11 → Vulkan → MoltenVK → Metal.
    case dxvk = "dxvk"
    /// DXMT: D3D11 → Metal. Default on a fresh install.
    case dxmt = "dxmt"

    public var displayName: String {
        switch self {
        case .d3dMetal: return "D3DMetal (GPTK)"
        case .dxvk: return "DXVK"
        case .dxmt: return "DXMT"
        }
    }

    /// Environment variables applied when this layer is active.
    public func environmentOverrides(dxvkHud: DXVKHUD = .off, dxvkAsync: Bool = true) -> [String: String] {
        switch self {
        case .d3dMetal:
            // GPTK stubs are Wine builtins (lib/wine PE + unix .so → libd3dshared).
            // Do not force d3d10core=b — this Wine tree has no d3d10core.so and Steam
            // dies if that override is present.
            // nvngx/nvapi64 = MetalFX (DLSS→MetalFX) complement from GPTK 3+.
            return [
                "WINEDLLOVERRIDES": "d3d11,dxgi,d3d12,d3d10,atidxx64,nvapi64,nvngx=b",
                "CX_GRAPHICS_BACKEND": "d3dmetal"
            ]
        case .dxvk:
            var env = ["WINEDLLOVERRIDES": "dxgi,d3d9,d3d10core,d3d11=n,b"]
            if dxvkAsync { env["DXVK_ASYNC"] = "1" }
            switch dxvkHud {
            case .full: env["DXVK_HUD"] = "full"
            case .partial: env["DXVK_HUD"] = "devinfo,fps,frametimes"
            case .fps: env["DXVK_HUD"] = "fps"
            case .off: break
            }
            return env
        case .dxmt:
            return ["WINEDLLOVERRIDES": "dxgi,d3d11,d3d10core=n,b"]
        }
    }

    public var requiresDXVKInstall: Bool {
        self == .dxvk
    }
}
