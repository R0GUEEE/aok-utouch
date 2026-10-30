import Foundation
import UIKit
import os

/// What the machine is doing, as far as the UI is concerned.
enum VMState: Equatable {
    case idle
    case booting
    case running
    case paused
    case stopped
    case failed(String)

    var label: String {
        switch self {
        case .idle: return "Not started"
        case .booting: return "Starting"
        case .running: return "Running"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        case .failed(let why): return "Failed: \(why)"
        }
    }
}

struct VMConfig: Codable, Equatable {
    var imageName = "alpine.img"
    var memoryMiB = 2560
    var cpus = 1
    /// Scanout size. Pixel count is the dominant cost under gadget
    /// interpretation, so this is a first-class setting and not a detail.
    var width = 1280
    var height = 720
    var extraArgs: [String] = []
}

// MARK: - C callback trampolines
//
// These must be top-level, non-capturing functions to be usable as C function
// pointers. Each one owns nothing; the context pointer is the FrameSink or the
// VMRuntime itself, unretained.

private func aokFrameTrampoline(_ ctx: UnsafeMutableRawPointer?,
                                _ base: UnsafePointer<UInt8>?,
                                _ stride: Int,
                                _ x: Int32, _ y: Int32,
                                _ w: Int32, _ h: Int32) {
    guard let ctx, let base else { return }
    Unmanaged<FrameSink>.fromOpaque(ctx).takeUnretainedValue()
        .blit(base: base, stride: stride, x: Int(x), y: Int(y), w: Int(w), h: Int(h))
}

private func aokResizeTrampoline(_ ctx: UnsafeMutableRawPointer?, _ width: Int32, _ height: Int32) {
    guard let ctx else { return }
    Unmanaged<FrameSink>.fromOpaque(ctx).takeUnretainedValue()
        .requestResize(width: Int(width), height: Int(height))
}

private func aokExitTrampoline(_ ctx: UnsafeMutableRawPointer?, _ status: Int32) {
    guard let ctx else { return }
    let runtime = Unmanaged<VMRuntime>.fromOpaque(ctx).takeUnretainedValue()
    Task { @MainActor in runtime.engineExited(status: Int(status)) }
}

// MARK: -

@MainActor
final class VMRuntime: ObservableObject {
    @Published private(set) var state: VMState = .idle
    @Published private(set) var consoleText: String = ""
    /// Non-nil while the bundled guest is being unpacked, 0...1.
    @Published private(set) var preparing: Double?
    @Published var config = VMConfig() {
        didSet { if oldValue != config { save() } }
    }
    /// Pixels land here from the engine thread; ScanoutView reads it on main.
    let sink = FrameSink()

    private let log = Logger(subsystem: "com.aok.vm", category: "engine")
    private var logTimer: DispatchSourceTimer?
    private let configKey = "AokVM.config"

    var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// An imported image wins; otherwise the guest that shipped in the app.
    var importedImageURL: URL? {
        guard !config.imageName.isEmpty else { return nil }
        let candidate = documents.appendingPathComponent(config.imageName)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    var imageURL: URL { importedImageURL ?? GuestImage.url }

    /// True when there is something to boot, either way round.
    var hasGuest: Bool {
        FileManager.default.fileExists(atPath: imageURL.path)
    }
    var logURL: URL { documents.appendingPathComponent("engine.log") }

    init() { load() }

    // MARK: Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: configKey),
              let decoded = try? JSONDecoder().decode(VMConfig.self, from: data) else { return }
        config = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: configKey)
        }
    }

    // MARK: Lifecycle

    func start() {
        guard state == .idle || state == .stopped || isFailed else { return }
        guard hasGuest else {
            unpackBundledGuest(thenStart: true)
            return
        }
        startEngine()
    }

    /// Unpacks the guest that ships in the bundle. Runs off the main thread;
    /// `progress` is published so the setup screen can show it.
    private func unpackBundledGuest(thenStart: Bool) {
        guard preparing == nil else { return }
        guard GuestImage.bundledURL != nil else {
            state = .failed("no guest image bundled and none imported")
            return
        }
        preparing = 0
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try GuestImage.installIfNeeded { fraction in
                    Task { @MainActor [weak self] in self?.preparing = fraction }
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.preparing = nil
                    if thenStart { self.startEngine() }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.preparing = nil
                    self?.state = .failed("could not unpack the guest: \(error.localizedDescription)")
                }
            }
        }
    }

    func resetGuest() {
        guard state == .idle || state == .stopped || isFailed else { return }
        try? GuestImage.reset()
        config.imageName = ""
        state = .idle
    }

    private func startEngine() {
        guard prepareVarsFirmware() else {
            state = .failed("Missing edk2 firmware in the bundle")
            return
        }

        try? FileManager.default.createDirectory(at: documents.appendingPathComponent("Logs"),
                                                 withIntermediateDirectories: true)
        let logPath = documents.appendingPathComponent("Logs/engine.log").path

        sink.reset()
        aok_ios_set_frame_cb(aokFrameTrampoline, Unmanaged.passUnretained(sink).toOpaque())
        aok_ios_set_resize_cb(aokResizeTrampoline, Unmanaged.passUnretained(sink).toOpaque())
        aok_ios_set_exit_cb(aokExitTrampoline, Unmanaged.passUnretained(self).toOpaque())
        aok_ios_set_log_path(logPath)

        let args = buildArguments()
        log.info("starting engine with \(args.count) arguments")
        state = .booting

        let result = args.withCStrings { argv, count in
            aok_ios_start(argv, Int32(count))
        }
        guard result == 0 else {
            state = .failed(result == -1 ? "engine already running" : "could not start engine thread")
            return
        }

        // qemu_init() builds the machine on the engine thread; do not hold the
        // main thread for it.
        Task.detached(priority: .userInitiated) { [weak self] in
            let ready = aok_ios_wait_ready(30_000)
            await MainActor.run { self?.engineReady(ready) }
        }
    }

    private func engineReady(_ ready: Int32) {
        switch ready {
        case 1:
            state = .running
            startLogTail()
        case 0:
            state = .failed("machine did not come up within 30 s")
            aok_ios_quit()
        default:
            state = .failed("engine thread died during init")
        }
    }

    func pause() {
        guard state == .running else { return }
        aok_ios_pause()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        aok_ios_resume()
        state = .running
    }

    func togglePause() {
        if state == .paused { resume() } else { pause() }
    }

    func shutdown() {
        guard isLive else { return }
        aok_ios_shutdown()
        state = .stopped
    }

    func stop() {
        aok_ios_quit()
    }

    fileprivate func engineExited(status: Int) {
        logTimer?.cancel(); logTimer = nil
        if case .failed = state { return }
        state = status == 0 ? .stopped : .failed("engine exited with \(status)")
    }

    var isLive: Bool {
        switch state {
        case .running, .paused, .booting: return true
        default: return false
        }
    }

    private var isFailed: Bool { if case .failed = state { return true }; return false }

    // MARK: Files

    private func prepareVarsFirmware() -> Bool {
        let bundle = Bundle.main
        for name in ["edk2-aarch64-code.fd", "edk2-arm-vars.fd"] {
            let src = bundle.url(forResource: name, withExtension: nil)
                ?? bundle.url(forResource: (name as NSString).deletingPathExtension,
                              withExtension: "fd")
            guard let src, FileManager.default.fileExists(atPath: src.path) else { return false }
            let dst = documents.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: dst.path) {
                try? FileManager.default.copyItem(at: src, to: dst)
            }
        }
        return true
    }

    /// Declared capacity, minus what iOS wants us to leave alone.
    private func clampedMemory() -> Int {
        let reported = aok_ios_available_memory()
        let availableMiB = reported > 0 ? Int(reported / (1024 * 1024)) : 2048
        let want = config.memoryMiB
        // Keep 900 MiB for the app, Metal, and the rest of the system.
        return max(768, min(want, availableMiB - 900))
    }

    /// QEMU finds option ROMs (vgabios-ramfb.bin, efi-virtio.rom) relative to
    /// the -L path; without it it looks in /usr/local/share/qemu and exits.
    private var romDirectory: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("pc-bios"),
              FileManager.default.fileExists(atPath: url.appendingPathComponent("vgabios-ramfb.bin").path)
        else { return nil }
        return url
    }

    func buildArguments() -> [String] {
        let fw = documents
        var args: [String] = [
            "qemu-system-aarch64",
            "-name", "aok-utouch",
        ]
        if let roms = romDirectory {
            args += ["-L", roms.path]
        } else {
            log.error("no pc-bios directory in the bundle; devices needing ROMs will fail")
        }
        args += [
            "-M", "virt,highmem=on",
            "-cpu", "max",
            "-smp", "\(max(1, min(config.cpus, 4)))",
            "-m", "\(clampedMemory())",
            "-rtc", "base=utc,clock=host",
            "-drive", "if=pflash,format=raw,readonly=on,file=\(fw.appendingPathComponent("edk2-aarch64-code.fd").path)",
            "-drive", "if=pflash,format=raw,file=\(fw.appendingPathComponent("edk2-arm-vars.fd").path)",
            "-device", "virtio-ramfb,xres=\(config.width),yres=\(config.height)",
            "-drive", "if=none,id=hd0,format=raw,cache=writeback,file=\(imageURL.path)",
            "-device", "virtio-blk-pci,drive=hd0",
            "-netdev", "user,id=n0",
            "-device", "virtio-net-pci,netdev=n0",
            "-device", "virtio-keyboard-pci",
            "-device", "virtio-tablet-pci",
            "-display", "none",
            "-monitor", "none",
            "-nodefaults",
            "-no-user-config",
        ]
        args.append(contentsOf: config.extraArgs)
        return args
    }

    // MARK: Log tail

    private func startLogTail() {
        let url = documents.appendingPathComponent("Logs/engine.log")
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard let handle = try? FileHandle(forReadingFrom: url) else { return }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            let window: UInt64 = 16 * 1024
            try? handle.seek(toOffset: size > window ? size - window : 0)
            if let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) {
                let lines = text.split(separator: "\n").suffix(200)
                self.consoleText = lines.joined(separator: "\n")
            }
        }
        timer.resume()
        logTimer = timer
    }
}

// MARK: - argv marshalling

private extension Array where Element == String {
    /// Builds the NULL-terminated char** QEMU expects and hands it to `body`.
    func withCStrings<T>(_ body: (UnsafePointer<UnsafePointer<CChar>?>, Int) -> T) -> T {
        var copies: [UnsafeMutablePointer<CChar>] = []
        var pointers: [UnsafePointer<CChar>?] = []
        for string in self {
            if let copy = strdup(string) {
                copies.append(copy)
                pointers.append(UnsafePointer(copy))
            } else {
                pointers.append(nil)
            }
        }
        defer { for copy in copies { free(copy) } }
        var terminated = pointers
        terminated.append(nil)
        return terminated.withUnsafeBufferPointer { buffer in
            body(buffer.baseAddress!, count)
        }
    }
}
