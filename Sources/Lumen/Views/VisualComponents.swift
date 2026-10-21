import SwiftUI
import AppKit
import LumenCore

enum LumenStyle {
    static let mint = Color(red: 0.60, green: 0.94, blue: 0.80)
    static let secondary = Color.white.opacity(0.46)
    static let line = Color.white.opacity(0.09)
}

struct WindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct LumenBackground: View {
    var body: some View {
        ZStack {
            WindowMaterial()
            Color(red: 0.055, green: 0.075, blue: 0.09).opacity(0.84)
            GeometryReader { geometry in
                Rectangle()
                    .fill(RadialGradient(
                        stops: [
                            .init(color: Color(red: 0.22, green: 0.46, blue: 0.43).opacity(0.16), location: 0),
                            .init(color: Color(red: 0.22, green: 0.46, blue: 0.43).opacity(0.045), location: 0.55),
                            .init(color: .clear, location: 1)
                        ],
                        center: UnitPoint(x: 0.88, y: 0.02),
                        startRadius: 0,
                        endRadius: max(geometry.size.width, geometry.size.height) * 0.8
                    ))
                Rectangle()
                    .fill(RadialGradient(
                        stops: [
                            .init(color: Color(red: 0.20, green: 0.26, blue: 0.43).opacity(0.13), location: 0),
                            .init(color: Color(red: 0.20, green: 0.26, blue: 0.43).opacity(0.035), location: 0.55),
                            .init(color: .clear, location: 1)
                        ],
                        center: UnitPoint(x: 0.02, y: 0.95),
                        startRadius: 0,
                        endRadius: max(geometry.size.width, geometry.size.height) * 0.7
                    ))
            }
        }
        .ignoresSafeArea()
    }
}

struct LumenMark: View {
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.17)
                .fill(LumenStyle.mint.opacity(0.18))
                .frame(width: size * 0.65, height: size * 0.65)
                .offset(x: -size * 0.13, y: size * 0.13)
            RoundedRectangle(cornerRadius: size * 0.17)
                .fill(LinearGradient(colors: [Color(red: 0.78, green: 1, blue: 0.89), LumenStyle.mint.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size * 0.65, height: size * 0.65)
                .offset(x: size * 0.13, y: -size * 0.13)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension GuestOS {
    var tint: Color {
        switch self {
        case .macOS: return Color(red: 0.56, green: 0.88, blue: 0.72)
        case .ubuntu: return Color(red: 1, green: 0.63, blue: 0.37)
        case .debian: return Color(red: 0.99, green: 0.44, blue: 0.58)
        case .arch: return Color(red: 0.41, green: 0.74, blue: 0.99)
        case .voidLinux: return Color(red: 0.66, green: 0.83, blue: 0.39)
        case .abyssLinux: return Color(red: 0.659, green: 0.333, blue: 0.969) // #a855f7
        case .linux: return Color(red: 0.86, green: 0.76, blue: 0.53)
        case .windows: return Color(red: 0.46, green: 0.71, blue: 1)
        case .android: return Color(red: 0.60, green: 0.83, blue: 0.51)
        case .chromeOS: return Color(red: 0.70, green: 0.70, blue: 0.79)
        }
    }

    var shortDescription: String {
        switch self {
        case .macOS: return "Apple silicon · IPSW"
        case .ubuntu: return "ARM64 · ISO"
        case .debian: return "ARM64 · ISO"
        case .arch: return "ARM64 · custom image"
        case .voidLinux: return "AArch64 · custom image"
        case .abyssLinux: return "AArch64 · dwm live ISO"
        case .linux: return "ARM64 · UEFI ISO"
        case .windows: return "ARM64 · experimental"
        case .android: return "Not available yet"
        case .chromeOS: return "Not available yet"
        }
    }
}

struct GuestGlyph: View {
    let guest: GuestOS
    var size: CGFloat = 26

    var body: some View {
        if let logo = GuestLogo.image(for: guest) {
            Image(nsImage: logo)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size * 1.05, height: size * 1.05)
                .clipShape(Circle())
                .overlay { Circle().strokeBorder(guest.tint.opacity(0.45), lineWidth: max(1, size * 0.04)) }
                .frame(width: size * 1.15, height: size * 1.15)
                .accessibilityHidden(true)
        } else {
            symbolGlyph
        }
    }

    private var symbolGlyph: some View {
        Group {
            switch guest {
            case .macOS:
                Image(systemName: "applelogo").font(.system(size: size, weight: .medium))
            case .windows:
                Grid(horizontalSpacing: size * 0.08, verticalSpacing: size * 0.08) {
                    GridRow { Rectangle(); Rectangle() }
                    GridRow { Rectangle(); Rectangle() }
                }
                .frame(width: size * 0.8, height: size * 0.8)
                .rotationEffect(.degrees(-5))
            case .ubuntu:
                ZStack {
                    Circle().stroke(lineWidth: size * 0.11).padding(size * 0.17)
                    ForEach(0..<3) { index in
                        Circle()
                            .frame(width: size * 0.24, height: size * 0.24)
                            .offset(y: -size * 0.39)
                            .rotationEffect(.degrees(Double(index) * 120 + 30))
                    }
                }
                .frame(width: size, height: size)
            case .arch:
                Image(systemName: "mountain.2.fill").font(.system(size: size * 0.88, weight: .medium))
            case .debian:
                Image(systemName: "hurricane").font(.system(size: size, weight: .medium))
            case .voidLinux:
                Image(systemName: "circle.hexagongrid.fill").font(.system(size: size * 0.9, weight: .medium))
            case .abyssLinux:
                Image(systemName: guest.symbol).font(.system(size: size * 0.9, weight: .medium))
            case .linux:
                Image(systemName: "terminal.fill").font(.system(size: size * 0.9, weight: .medium))
            case .android:
                Image(systemName: "apps.iphone").font(.system(size: size * 0.9, weight: .medium))
            case .chromeOS:
                Image(systemName: "globe.americas.fill").font(.system(size: size * 0.9, weight: .medium))
            }
        }
        .foregroundStyle(guest.tint)
        .frame(width: size * 1.15, height: size * 1.15)
        .accessibilityHidden(true)
    }
}

struct GuestBadge: View {
    let guest: GuestOS
    var size: CGFloat = 54

    var body: some View {
        GuestGlyph(guest: guest, size: size * 0.48)
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                    .fill(LinearGradient(colors: [guest.tint.opacity(0.16), guest.tint.opacity(0.045)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                            .strokeBorder(guest.tint.opacity(0.16), lineWidth: 1)
                    }
            }
    }
}

struct CapsuleButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? Color(red: 0.08, green: 0.18, blue: 0.15) : .white.opacity(0.82))
            .padding(.horizontal, 17)
            .padding(.vertical, 11)
            .background {
                Capsule()
                    .fill(prominent ? LumenStyle.mint.opacity(configuration.isPressed ? 0.75 : 1) : Color.white.opacity(configuration.isPressed ? 0.13 : 0.055))
                    .overlay { Capsule().strokeBorder(Color.white.opacity(prominent ? 0.2 : 0.09), lineWidth: 1) }
            }
            .opacity(configuration.isPressed ? 0.86 : 1)
            .contentShape(Capsule())
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.65))
            .frame(width: 34, height: 34)
            .background(Circle().fill(Color.white.opacity(configuration.isPressed ? 0.12 : 0.04)))
            .overlay { Circle().strokeBorder(Color.white.opacity(0.07), lineWidth: 1) }
            .contentShape(Circle())
    }
}

struct TinyLabel: View {
    let text: String
    var color: Color = LumenStyle.secondary

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(1.3)
            .foregroundStyle(color)
    }
}

// MARK: - Bundled Guest Logos

/// Raster logos shipped in `Contents/Resources/GuestLogos`, used instead of SF Symbols when present.
@MainActor
enum GuestLogo {
    private static var cache: [GuestOS: NSImage] = [:]
    private static var missing: Set<GuestOS> = []

    static func resourceName(for guest: GuestOS) -> String? {
        switch guest {
        case .abyssLinux: return "abyss"
        default: return nil
        }
    }

    static func image(for guest: GuestOS) -> NSImage? {
        if let cached = cache[guest] { return cached }
        guard !missing.contains(guest), let name = resourceName(for: guest),
              let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "GuestLogos"),
              let image = NSImage(contentsOf: url) else {
            missing.insert(guest)
            return nil
        }
        cache[guest] = image
        return image
    }
}

// MARK: - Dynamic Guest Dock Icon Generator

@MainActor
public enum GuestIconGenerator {
    private static var iconCache: [GuestOS: NSImage] = [:]

    public static func icon(for guest: GuestOS) -> NSImage {
        if let cached = iconCache[guest] { return cached }

        if let logo = GuestLogo.image(for: guest) {
            let image = logoIcon(logo, tint: guest.tint)
            iconCache[guest] = image
            return image
        }

        let iconView = ZStack {
            RoundedRectangle(cornerRadius: 56, style: .continuous)
                .fill(gradient(for: guest))
                .overlay(
                    RoundedRectangle(cornerRadius: 56, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 1.5)
                )
                .shadow(color: Color.black.opacity(0.35), radius: 10, y: 5)

            GuestGlyph(guest: guest, size: 105)
                .foregroundStyle(.white)
                .shadow(color: Color.black.opacity(0.28), radius: 6, y: 3)
        }
        .frame(width: 256, height: 256)

        let renderer = ImageRenderer(content: iconView)
        renderer.scale = 2.0
        let image = renderer.nsImage ?? NSImage()
        iconCache[guest] = image
        return image
    }

    /// A Dock-sized squircle filled edge to edge with the guest's own artwork.
    private static func logoIcon(_ logo: NSImage, tint: Color) -> NSImage {
        let shape = RoundedRectangle(cornerRadius: 56, style: .continuous)
        let iconView = Image(nsImage: logo)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: 228, height: 228)
            .clipShape(shape)
            .overlay(shape.strokeBorder(tint.opacity(0.55), lineWidth: 2))
            .shadow(color: Color.black.opacity(0.35), radius: 10, y: 5)
            .frame(width: 256, height: 256)

        let renderer = ImageRenderer(content: iconView)
        renderer.scale = 2.0
        return renderer.nsImage ?? logo
    }

    private static func gradient(for guest: GuestOS) -> LinearGradient {
        switch guest {
        case .ubuntu:
            return LinearGradient(
                colors: [Color(red: 0.95, green: 0.40, blue: 0.13), Color(red: 0.46, green: 0.10, blue: 0.28)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .windows:
            return LinearGradient(
                colors: [Color(red: 0.05, green: 0.48, blue: 0.88), Color(red: 0.01, green: 0.22, blue: 0.58)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .macOS:
            return LinearGradient(
                colors: [Color(red: 0.35, green: 0.55, blue: 0.75), Color(red: 0.12, green: 0.22, blue: 0.42)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .debian:
            return LinearGradient(
                colors: [Color(red: 0.88, green: 0.15, blue: 0.32), Color(red: 0.45, green: 0.05, blue: 0.18)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .arch:
            return LinearGradient(
                colors: [Color(red: 0.12, green: 0.58, blue: 0.88), Color(red: 0.04, green: 0.22, blue: 0.45)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .voidLinux:
            return LinearGradient(
                colors: [Color(red: 0.38, green: 0.68, blue: 0.28), Color(red: 0.12, green: 0.32, blue: 0.12)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .abyssLinux:
            return LinearGradient(
                colors: [Color(red: 0.66, green: 0.33, blue: 0.97), Color(red: 0.16, green: 0.05, blue: 0.32)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        case .linux:
            return LinearGradient(
                colors: [Color(red: 0.82, green: 0.68, blue: 0.32), Color(red: 0.35, green: 0.25, blue: 0.10)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        default:
            return LinearGradient(
                colors: [Color(red: 0.22, green: 0.32, blue: 0.42), Color(red: 0.10, green: 0.15, blue: 0.22)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
        }
    }
}

