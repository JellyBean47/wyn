//
//  WynBrand.swift
//  WynKit
//
//  This file is part of Wyn.
//

import Foundation

/// Product identity. "wyn" is Afrikaans/Dutch for wine — same alcohol-naming
/// family as Whisky, the Wine wrapper this tree started from.
public enum WynBrand {
    public static let name = "Wyn"
    public static let command = "wyn"

    /// Logger / future app id. The CLI has no bundle identifier of its own.
    public static let bundleIdentifier = "com.wyn.gaming"

    /// Frozen on-disk folder name. Bottles, Wine trees, logs, and Tools scripts
    /// live here. Do not change — renaming would orphan the Steam bottle and
    /// multi-GB `Libraries/` trees already installed under `com.fly.gaming`.
    public static let supportIdentifier = "com.fly.gaming"
}
