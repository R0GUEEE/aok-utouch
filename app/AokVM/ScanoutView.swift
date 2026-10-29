import UIKit
import Metal
import QuartzCore
import CoreVideo
import IOSurface

/// Shared between the engine thread (writer) and the display link (reader).
///
/// The engine hands us a pointer into the guest's scanout memory. We memcpy the
/// dirty rect into an IOSurface straight away, because that pointer is only
/// valid for the duration of the callback. Nothing here touches UIKit, so the
/// writer side is safe off the main thread.
final class FrameSink: @unchecked Sendable {
    private let lock = NSLock()
    private var surface: IOSurface?
    private var base: UnsafeMutableRawPointer?
    private var bytesPerRow = 0
    private var dirty = false
    private var generation: Int = 0

    private(set) var width = 0
    private(set) var height = 0

    var ioSurface: IOSurface? {
        lock.lock(); defer { lock.unlock() }
        return surface
    }

    var generationNumber: Int {
        lock.lock(); defer { lock.unlock() }
        return generation
    }

    func reset() {
        lock.lock()
        surface = nil
        base = nil
        bytesPerRow = 0
        width = 0
        height = 0
        dirty = false
        generation += 1
        lock.unlock()
    }

    func requestResize(width newWidth: Int, height newHeight: Int) {
        guard newWidth > 0, newHeight > 0 else { return }
        lock.lock()
        allocateLocked(width: newWidth, height: newHeight)
        dirty = true
        generation += 1
        lock.unlock()
    }

    private func allocateLocked(width newWidth: Int, height newHeight: Int) {
        if width == newWidth && height == newHeight && surface != nil { return }

        let rowBytes = newWidth * 4
        let props: [CFString: Any] = [
            kIOSurfaceWidth: newWidth,
            kIOSurfaceHeight: newHeight,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: rowBytes,
            kIOSurfaceAllocSize: rowBytes * newHeight,
            kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA,
            kIOSurfaceIsGlobal: false,
        ]
        guard let created = IOSurfaceCreate(props as CFDictionary) else { return }
        IOSurfaceLock(created, [], nil)
        base = IOSurfaceGetBaseAddress(created)
        IOSurfaceUnlock(created, [], nil)

        surface = created
        bytesPerRow = rowBytes
        width = newWidth
        height = newHeight
    }

    func blit(base src: UnsafePointer<UInt8>, stride: Int,
              x: Int, y: Int, w: Int, h: Int) {
        lock.lock(); defer { lock.unlock() }

        if surface == nil {
            // First frame before the switch callback: size from the frame.
            allocateLocked(width: max(width, x + w), height: max(height, y + h))
        }
        guard let surface, let base, w > 0, h > 0 else { return }
        guard x >= 0, y >= 0, x + w <= width, y + h <= height else { return }

        IOSurfaceLock(surface, [], nil)
        let dstRow = base.advanced(by: y * bytesPerRow + x * 4)
        let srcRow = UnsafeRawPointer(src).advanced(by: y * stride + x * 4)
        if stride == bytesPerRow && w * 4 == bytesPerRow {
            memcpy(dstRow, srcRow, w * h * 4)
        } else {
            for row in 0..<h {
                memcpy(dstRow.advanced(by: row * bytesPerRow),
                       srcRow.advanced(by: row * stride),
                       w * 4)
            }
        }
        IOSurfaceUnlock(surface, [], nil)

        dirty = true
    }

    /// Called by the display link. Returns true when there is something new.
    func takeDirty() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if dirty { dirty = false; return true }
        return false
    }
}

/// A CAMetalLayer that draws one textured quad, letterboxed to the guest's
/// aspect ratio. One draw call per vsync, no Core Graphics anywhere.
final class ScanoutView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private var pipeline: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?
    private var texture: MTLTexture?
    private var pixelBuffer: CVPixelBuffer?
    private var textureGeneration = -1
    private var displayLink: CADisplayLink?
    private var targetFPS = 60

    let sink: FrameSink

    init(sink: FrameSink) {
        self.sink = sink
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fatalError("Metal is required to run the VM display")
        }
        self.device = device
        self.queue = queue
        super.init(frame: .zero)
        isOpaque = true
        backgroundColor = .black
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.allowsNextDrawableTimeout = true
        contentMode = .scaleAspectFit
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        buildPipeline()
        startDisplayLink()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { displayLink?.invalidate() }

    private func buildPipeline() {
        guard let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "vs_quad"),
              let fragment = library.makeFunction(name: "fs_scanout") else { return }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFramesPerSecond = targetFPS
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func setTargetFPS(_ fps: Int) {
        targetFPS = fps
        displayLink?.preferredFramesPerSecond = fps
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = UIScreen.main.scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale,
                                         height: bounds.height * scale)
    }

    @objc private func tick() {
        guard pipeline != nil else { return }
        _ = sink.takeDirty()
        let gen = sink.generationNumber
        if gen != textureGeneration { rebuildTexture(generation: gen) }
        // A stale texture still gets drawn: the black letterbox must appear
        // even before the guest's first frame.
        draw()
    }

    private func rebuildTexture(generation: Int) {
        guard let cache = textureCache, let surface = sink.ioSurface else { return }

        // CVMetalTextureCacheCreateTextureFromImage takes a CVImageBuffer, not
        // an IOSurface; wrap it. The wrap is zero-copy - both sides point at the
        // same memory the engine is writing into.
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        guard CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface,
                                               attributes as CFDictionary,
                                               &buffer) == kCVReturnSuccess,
              let buffer else { return }
        pixelBuffer = buffer

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, buffer, nil, .bgra8Unorm,
            sink.width, sink.height, 0, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture,
              let metal = CVMetalTextureGetTexture(cvTexture) else { return }
        texture = metal
        textureGeneration = generation
    }

    private func draw() {
        guard let drawable = metalLayer.nextDrawable(),
              let pipeline, let texture else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        // Letterbox: scale the quad by the ratio of the drawable's aspect to
        // the guest's aspect, whichever is smaller.
        let guest = CGSize(width: CGFloat(max(sink.width, 1)),
                           height: CGFloat(max(sink.height, 1)))
        let host = metalLayer.drawableSize
        let scaleX = min(1, (guest.width / guest.height) / (host.width / max(host.height, 1)))
        let scaleY = min(1, (host.width / max(host.height, 1)) / (guest.width / guest.height))
        var scale = SIMD2<Float>(Float(scaleX), Float(scaleY))

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
