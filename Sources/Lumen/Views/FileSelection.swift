import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LumenCore

/// Keeps file panels attached to the wizard's own window instead of starting a
/// second application-modal event loop while a SwiftUI sheet is already open.
@MainActor
final class FilePanelCoordinator: ObservableObject {
    weak var window: NSWindow?
    private var activePanel: NSOpenPanel?

    func present(_ panel: NSOpenPanel, selected: @escaping (URL) -> Void) {
        presentMultiple(panel) { urls in if let first = urls.first { selected(first) } }
    }

    func presentMultiple(_ panel: NSOpenPanel, selected: @escaping ([URL]) -> Void) {
        guard activePanel == nil else { return }
        activePanel = panel
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.activePanel = nil
            if response == .OK { selected(panel.urls) }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

}

struct FilePanelAnchor: NSViewRepresentable {
    let coordinator: FilePanelCoordinator
    func makeNSView(context: Context) -> AnchorView { AnchorView(coordinator: coordinator) }
    func updateNSView(_ view: AnchorView, context: Context) { coordinator.window = view.window }

    final class AnchorView: NSView {
        let coordinator: FilePanelCoordinator
        init(coordinator: FilePanelCoordinator) {
            self.coordinator = coordinator
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() { coordinator.window = window }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct LocalFileDrop: ViewModifier {
    let folder: Bool
    let selected: (URL) -> Void
    let failed: (String) -> Void
    var installerFallback: ((URL) -> Void)? = nil
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
                guard !providers.isEmpty, folder || providers.count == 1 else {
                    failed("Drop one installer at a time.")
                    return true
                }
                for provider in providers {
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                        let url: URL?
                        if let value = item as? URL { url = value }
                        else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                        else if let value = item as? String { url = URL(string: value) }
                        else { url = nil }
                        DispatchQueue.main.async {
                            do {
                                guard error == nil, let url else {
                                    throw LibraryError.invalidConfiguration("The dropped file could not be opened. Try Browse instead.")
                                }
                                if folder {
                                    do {
                                        try LocalFileSelection.validateFolder(url)
                                        selected(url)
                                    } catch {
                                        guard providers.count == 1, let installerFallback else { throw error }
                                        try LocalFileSelection.validateInstaller(url)
                                        installerFallback(url)
                                    }
                                } else {
                                    try LocalFileSelection.validateInstaller(url)
                                    selected(url)
                                }
                            } catch { failed(error.localizedDescription) }
                        }
                    }
                }
                return true
            }
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(LumenStyle.mint, lineWidth: 2)
                        .background(RoundedRectangle(cornerRadius: 14).fill(LumenStyle.mint.opacity(0.08)))
                        .overlay(alignment: .top) {
                            Label(folder ? "Drop folders to share" : "Drop ISO or IPSW installer", systemImage: "arrow.down.doc")
                                .font(.system(size: 12, weight: .semibold))
                                .padding(12)
                                .background(.regularMaterial, in: Capsule())
                                .padding(12)
                        }
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    func guestFilesDrop(enabled: Bool, selected: @escaping ([URL]) -> Void, failed: @escaping (String) -> Void) -> some View {
        modifier(GuestFilesDrop(enabled: enabled, selected: selected, failed: failed))
    }
    func installerDrop(selected: @escaping (URL) -> Void, failed: @escaping (String) -> Void) -> some View {
        modifier(LocalFileDrop(folder: false, selected: selected, failed: failed))
    }
    func sharedFolderDrop(selected: @escaping (URL) -> Void, installer: ((URL) -> Void)? = nil, failed: @escaping (String) -> Void) -> some View {
        modifier(LocalFileDrop(folder: true, selected: selected, failed: failed, installerFallback: installer))
    }
}

private struct GuestFilesDrop: ViewModifier {
    let enabled: Bool
    let selected: ([URL]) -> Void
    let failed: (String) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content.onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            guard enabled else { return false }
            guard !providers.isEmpty, providers.count <= 128 else {
                failed("Drop between 1 and 128 files or folders at a time.")
                return true
            }
            var remaining = providers.count
            var urls: [URL] = []
            var invalid = false
            for provider in providers {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    let url: URL?
                    if let value = item as? URL { url = value }
                    else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else if let value = item as? String { url = URL(string: value) }
                    else { url = nil }
                    DispatchQueue.main.async {
                        if error == nil, let url, url.isFileURL { urls.append(url) }
                        else { invalid = true }
                        remaining -= 1
                        if remaining == 0 {
                            if invalid { failed("Some dropped files could not be opened. Use Send files instead.") }
                            else { selected(urls) }
                        }
                    }
                }
            }
            return true
        }
        .overlay {
            if enabled && targeted {
                RoundedRectangle(cornerRadius: 14).strokeBorder(LumenStyle.mint, lineWidth: 2)
                    .overlay(alignment: .top) {
                        Text("Send files to a shared folder")
                            .padding(12).background(.regularMaterial, in: Capsule()).padding(12)
                    }.allowsHitTesting(false)
            }
        }
    }
}
