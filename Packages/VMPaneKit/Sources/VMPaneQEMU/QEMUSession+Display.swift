import Foundation
import VMPaneCore

/// Screenshots (`screendump`) and synthetic input over QMP.
extension QEMUSession {
    func screenshot(maxEdge: Int) async throws -> Screenshot {
        let pixels = try await capture()
        guard let image = QEMUScreenshot.image(pixels), let shot = ScreenshotEncoder.png(image, maxEdge: maxEdge) else {
            throw QEMUScreenshotError.invalidImage("encoding")
        }
        let scale = ScreenshotEncoder.scale(width: image.width, height: image.height, maxEdge: maxEdge)
        return Screenshot(png: shot.png, width: shot.width, height: shot.height, scale: scale)
    }

    /// The display reduced for input verification. `screendump` writes a full-size file per call, so it is the
    /// fallback: the helper app's SPICE client has the frames in memory.
    func grayFrame() async -> GrayFrame? {
        guard let pixels = try? await capture(), let image = QEMUScreenshot.image(pixels) else { return nil }
        return GrayFrame(image)
    }

    /// `screendump` into the run directory, read back (no symlinks, size capped) and deleted.
    func capture() async throws -> QEMUScreenshot.Pixels {
        guard let current = running else { throw QEMUBackendError.notRunning }
        let file = current.layout.runDirectory.appendingPathComponent("shot-\(UUID().uuidString).ppm")
        defer { try? FileManager.default.removeItem(at: file) }
        try await current.qmp.execute("screendump", ["filename": .string(file.path)], timeout: .seconds(10))
        let pixels = try QEMUScreenshot.decodePPM(
            try Self.readCapped(file, limit: QEMUScreenshot.maxDimension * QEMUScreenshot.maxDimension * 3 + 64))
        displaySize = (pixels.width, pixels.height)
        displaySizeAge = .now
        return pixels
    }

    func send(_ input: InputEvent) async throws {
        guard let current = running else { throw QEMUBackendError.notRunning }
        // Pointer coordinates need the current display size (the guest can change resolution).
        if case .pointer = input, displaySize == nil || displaySizeAge.map({ $0.duration(to: .now) > .seconds(5) }) ?? true {
            _ = try await capture()
        }
        let size = displaySize ?? (config.display.widthPx, config.display.heightPx)
        for step in try QEMUInput.steps(for: input, display: size, pressed: &pressedButtons) {
            switch step {
            case .command(let command, let arguments): try await current.qmp.execute(command, arguments)
            case .pause(let duration): try await Task.sleep(for: duration)
            }
        }
    }

    static func readCapped(_ url: URL, limit: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError.current() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try handle.read(upToCount: limit + 1), data.count <= limit else {
            throw QEMUScreenshotError.invalidImage("too large")
        }
        return data
    }
}
