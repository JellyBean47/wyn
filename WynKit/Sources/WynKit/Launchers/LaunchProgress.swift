//
//  LaunchProgress.swift
//  WynKit
//
//  Stdout plus an optional TaskLocal sink so the library overlay can show
//  SteamLauncher / ConnectLauncher steps while a launch is in flight.
//

import Foundation

public enum LaunchProgress: Sendable {
    @TaskLocal public static var sink: (@Sendable (String) -> Void)?

    public static func emit(_ message: String) {
        print(message)
        fflush(stdout)
        sink?(message)
    }
}
