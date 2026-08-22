//
//  GameTile.swift
//  Wyn
//
//  This file is part of Wyn.
//

import SwiftUI
import WynKit

struct GameTile: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let isSelected: Bool
    var platformKind: PlatformKind? = nil
    var steamAppId: Int? = nil
    var bottle: Bottle? = nil

    var body: some View {
        Group {
            if let platformKind {
                platformTile(kind: platformKind)
            } else {
                capsuleTile
            }
        }
    }

    private func platformTile(kind: PlatformKind) -> some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(platformFill(kind))
                    .frame(height: 88)
                if kind == .steam {
                    Image("WynLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 56, height: 56)
                } else {
                    Image(systemName: kind.systemImage)
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.94))
                }
            }
            Text(title)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .top)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.08), lineWidth: isSelected ? 2 : 1)
        }
        .shadow(color: .black.opacity(0.12), radius: isSelected ? 8 : 2, y: 2)
    }

    private var capsuleTile: some View {
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                ZStack(alignment: .bottom) {
                    cover
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.82)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.12), lineWidth: isSelected ? 2.5 : 1)
            }
            .shadow(color: .black.opacity(0.28), radius: isSelected ? 10 : 4, y: 3)
    }

    @ViewBuilder
    private var cover: some View {
        if let steamAppId {
            CoverImage(appId: steamAppId, bottle: bottle) {
                placeholderCover
            }
        } else {
            placeholderCover
        }
    }

    private var placeholderCover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 0)
                .fill(gameFill)
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
    }

    private func platformFill(_ kind: PlatformKind) -> LinearGradient {
        switch kind {
        case .steam:
            return LinearGradient(
                colors: [
                    Color(red: 0.29, green: 0.07, blue: 0.10),
                    Color(red: 0.45, green: 0.12, blue: 0.16)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .ubisoft:
            return LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.18, blue: 0.32),
                    Color(red: 0.10, green: 0.42, blue: 0.58)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .rockstar:
            return LinearGradient(
                colors: [
                    Color(red: 0.22, green: 0.14, blue: 0.04),
                    Color(red: 0.72, green: 0.52, blue: 0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .epic:
            return LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.08, blue: 0.10),
                    Color(red: 0.22, green: 0.22, blue: 0.26)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .ea:
            return LinearGradient(
                colors: [
                    Color(red: 0.28, green: 0.04, blue: 0.08),
                    Color(red: 0.55, green: 0.08, blue: 0.14)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .battlenet:
            return LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.16, blue: 0.38),
                    Color(red: 0.12, green: 0.38, blue: 0.72)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .gog:
            return LinearGradient(
                colors: [
                    Color(red: 0.28, green: 0.12, blue: 0.38),
                    Color(red: 0.48, green: 0.22, blue: 0.58)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var gameFill: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.18, green: 0.16, blue: 0.18),
                Color(red: 0.28, green: 0.10, blue: 0.14)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
