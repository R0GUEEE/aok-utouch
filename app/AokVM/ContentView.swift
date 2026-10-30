import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var runtime: VMRuntime

    var body: some View {
        Group {
            if runtime.isLive {
                VMScreen()
            } else {
                SetupView()
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Setup

struct SetupView: View {
    @EnvironmentObject private var runtime: VMRuntime
    @State private var importing = false
    @State private var showingConsole = false
    @State private var importError: String?

    private let resolutions: [(String, Int, Int)] = [
        ("1280 x 720", 1280, 720),
        ("1024 x 600", 1024, 600),
        ("960 x 540", 960, 540),
        ("1600 x 900", 1600, 900),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Guest") {
                    if let fraction = runtime.preparing {
                        ProgressView(value: fraction) {
                            Text("Unpacking the bundled Alpine guest")
                                .font(.footnote)
                        } currentValueLabel: {
                            Text("\(Int(fraction * 100))%")
                                .font(.caption.monospacedDigit())
                        }
                    } else if runtime.hasGuest {
                        LabeledContent("Image", value: runtime.importedImageURL == nil
                                       ? "Alpine (bundled)" : runtime.config.imageName)
                        let attributes = try? FileManager.default
                            .attributesOfItem(atPath: runtime.imageURL.path)
                        let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                        LabeledContent("Size",
                                       value: ByteCountFormatter.string(fromByteCount: bytes,
                                                                        countStyle: .file))
                    } else {
                        Text("The Alpine guest that ships with the app is unpacked into "
                             + "Application Support the first time you start it — about "
                             + "175 MB. No import needed.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button("Import a different image…") { importing = true }
                    if runtime.importedImageURL != nil, runtime.preparing == nil {
                        Button("Use the bundled guest again", role: .destructive) {
                            runtime.resetGuest()
                        }
                    }
                    if let importError {
                        Text(importError).font(.caption).foregroundStyle(.red)
                    }
                }

                Section("Machine") {
                    Stepper("Memory: \(runtime.config.memoryMiB) MiB",
                            value: $runtime.config.memoryMiB, in: 1024...6144, step: 256)
                    Stepper("CPUs: \(runtime.config.cpus)",
                            value: $runtime.config.cpus, in: 1...4)
                    Picker("Scanout", selection: Binding(
                        get: { "\(runtime.config.width) x \(runtime.config.height)" },
                        set: { label in
                            if let match = resolutions.first(where: { $0.0 == label }) {
                                runtime.config.width = match.1
                                runtime.config.height = match.2
                            }
                        })) {
                        ForEach(resolutions, id: \.0) { item in
                            Text(item.0).tag(item.0)
                        }
                    }
                    Text("Pixel count is the dominant cost under gadget interpretation. " +
                         "Drop to 1024 x 600 if the shell stutters.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        runtime.start()
                    } label: {
                        Label("Start Alpine", systemImage: "play.fill")
                    }
                    .disabled(runtime.preparing != nil)
                }

                Section("Engine") {
                    Button("Show engine log") { showingConsole = true }
                    if case .failed(let why) = runtime.state {
                        Text(why).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("AOK VM")
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [.data],
                          allowsMultipleSelection: false) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                importImage(from: url)
            }
            .sheet(isPresented: $showingConsole) {
                NavigationStack {
                    ScrollView {
                        Text(runtime.consoleText.isEmpty ? "No output yet." : runtime.consoleText)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .navigationTitle("Engine log")
                }
            }
        }
    }

    private func importImage(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let destination = runtime.documents.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: destination)
        do {
            // Copy, not move: the source may be read-only (iCloud, another app).
            try FileManager.default.copyItem(at: url, to: destination)
            runtime.config.imageName = url.lastPathComponent
        } catch {
            importError = "Could not import \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }
}

// MARK: - Live VM

struct VMScreen: View {
    @EnvironmentObject private var runtime: VMRuntime
    @State private var toolbarVisible = true
    @State private var consoleVisible = false
    @State private var keyboardUp = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            ScanoutRepresentable(sink: runtime.sink)
                .ignoresSafeArea()

            InputRepresentable(guestWidth: runtime.sink.width,
                               guestHeight: runtime.sink.height,
                               keyboardUp: keyboardUp)
                .ignoresSafeArea()

            if consoleVisible {
                consoleDrawer
            }

            if toolbarVisible {
                toolbar
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 4) {
            withAnimation(.easeInOut(duration: 0.2)) { toolbarVisible.toggle() }
        }
        .animation(.easeInOut(duration: 0.2), value: toolbarVisible)
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Label(runtime.state.label, systemImage: runtime.state == .paused
                  ? "pause.circle" : "cpu")
                .font(.caption)
                .labelStyle(.titleAndIcon)

            Spacer()

            Button { consoleVisible.toggle() } label: {
                Image(systemName: "text.alignleft")
            }
            Button { keyboardUp.toggle() } label: {
                Image(systemName: keyboardUp ? "keyboard.fill" : "keyboard")
            }
            Button { runtime.togglePause() } label: {
                Image(systemName: runtime.state == .paused ? "play.fill" : "pause.fill")
            }
            Button {
                runtime.shutdown()
            } label: {
                Image(systemName: "power")
            }
            Button {
                runtime.stop()
            } label: {
                Image(systemName: "xmark")
            }
        }
        .font(.system(size: 15, weight: .semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var consoleDrawer: some View {
        VStack {
            Spacer()
            ScrollView {
                Text(runtime.consoleText.isEmpty ? "Waiting for output…" : runtime.consoleText)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 200)
            .background(.black.opacity(0.75))
        }
        .ignoresSafeArea(edges: .bottom)
    }
}

// MARK: - UIKit bridges

struct ScanoutRepresentable: UIViewRepresentable {
    let sink: FrameSink

    func makeUIView(context: Context) -> ScanoutView {
        ScanoutView(sink: sink)
    }

    func updateUIView(_ uiView: ScanoutView, context: Context) {}
}

struct InputRepresentable: UIViewRepresentable {
    let guestWidth: Int
    let guestHeight: Int
    let keyboardUp: Bool

    func makeUIView(context: Context) -> InputView {
        let view = InputView(frame: .zero)
        view.guestWidth = guestWidth
        view.guestHeight = guestHeight
        return view
    }

    func updateUIView(_ uiView: InputView, context: Context) {
        uiView.guestWidth = guestWidth
        uiView.guestHeight = guestHeight
        if keyboardUp, !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !keyboardUp, uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }
}
