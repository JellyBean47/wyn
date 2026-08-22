//
//  CoverImage.swift
//  Wyn
//
//  This file is part of Wyn.
//

import AppKit
import SwiftUI
import WynKit

struct CoverImage<Placeholder: View>: View {
    let appId: Int
    let bottle: Bottle?
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: NSImage?

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    placeholder()
                }
            }
            .clipped()
            .task(id: appId) {
            image = nil
            if let data = await SteamArtwork.imageData(for: appId, in: bottle) {
                image = NSImage(data: data)
            }
        }
    }
}
