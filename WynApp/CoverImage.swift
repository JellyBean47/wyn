//
//  CoverImage.swift
//  Wyn
//
//  This file is part of Wyn.
//
//  Wyn is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Wyn is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Wyn.
//  If not, see https://www.gnu.org/licenses/.
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
