import Foundation
import AVFoundation
import CoreMedia
import CabrioDomain
import CabrioPorts

public struct AVFoundationEngine: MediaEngine {
    public init() {}

    // MARK: Audio

    public func audioToM4A(_ input: URL, output: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: input)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty else {
            throw CabrioError.unsupported(tr("«%@» no tiene audio.", input.lastPathComponent))
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CabrioError.unsupported(tr("Este Mac no puede crear audio M4A."))
        }
        let box = ExportBox(session)
        try? FileManager.default.removeItem(at: output)
        try await withTaskCancellationHandler {
            try await box.run(to: output, type: .m4a, progress: progress)
        } onCancel: { box.cancel() }
    }

    // MARK: Video

    private struct Plan {
        var width: Int
        var height: Int
        var videoBps: Double
        var audioBps: Double
    }

    public func compressVideo(_ input: URL, target: VideoTarget, hevc: Bool, output: URL,
                              progress: @escaping @Sendable (Double) -> Void) async throws -> CompressionReport {
        let name = input.lastPathComponent
        let asset = AVURLAsset(url: input)
        guard let video = try? await asset.loadTracks(withMediaType: .video).first else {
            throw CabrioError.unsupported(tr("«%@» no tiene video.", name))
        }
        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
        let hasAudio = audioTrack != nil
        guard let duration = try? await asset.load(.duration).seconds, duration > 0,
              let natural = try? await video.load(.naturalSize) else { throw CabrioError.unreadableFile(name) }
        let fps = max(Double((try? await video.load(.nominalFrameRate)) ?? 30), 1)
        let sourceBps = Double((try? await video.load(.estimatedDataRate)) ?? 0)
        let originalBytes = Int64((try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)

        // Resolución máxima (lado mayor) y bits por píxel según el objetivo.
        var cap = Double(max(natural.width, natural.height))
        var bpp = 0.10
        var limit: Int64?
        switch target {
        case .keepQuality: bpp = 0.20
        case .level(.low): cap = min(cap, 1920); bpp = 0.10
        case .level(.medium): cap = min(cap, 1280); bpp = 0.06
        case .level(.high): cap = min(cap, 854); bpp = 0.035
        case .maxBytes(let l): limit = l; cap = min(cap, 1920)
        }
        if hevc { bpp *= 0.65 }
        func dims() -> (Int, Int) {
            let s = min(1, cap / Double(max(natural.width, natural.height)))
            func even(_ v: Double) -> Int { max(Int((v * s).rounded()) / 2 * 2, 2) }
            return (even(Double(natural.width)), even(Double(natural.height)))
        }

        var plan: Plan
        let (w0, h0) = dims()
        if let limit {
            let audioBps = hasAudio ? min(128_000, max(48_000, Double(limit) * 8 * 0.1 / duration)) : 0
            let budget = max((Double(limit) * 8 * 0.92 - audioBps * duration) / duration, 50_000)
            plan = Plan(width: w0, height: h0, videoBps: budget, audioBps: audioBps)
        } else {
            var bps = Double(w0 * h0) * fps * bpp
            if sourceBps > 0 { bps = min(bps, sourceBps) }
            plan = Plan(width: w0, height: h0, videoBps: max(bps, 100_000), audioBps: hasAudio ? 128_000 : 0)
        }

        let attempts = limit == nil ? 1 : 4
        var size: Int64 = 0
        var previous: Int64 = 0
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            if limit != nil {   // con poco presupuesto se baja la resolución antes que degradar a bloques
                let maxPixels = plan.videoBps / (fps * 0.035)
                let pixels = Double(plan.width * plan.height)
                if pixels > maxPixels {
                    let f = max((maxPixels / pixels).squareRoot(), 0.2)
                    plan.width = max(Int(Double(plan.width) * f) / 2 * 2, 2)
                    plan.height = max(Int(Double(plan.height) * f) / 2 * 2, 2)
                }
            }
            try? FileManager.default.removeItem(at: output)
            let base = Double(attempt)
            let t = try Transcoder(video: video, audio: audioTrack, asset: asset,
                                   width: plan.width, height: plan.height, videoBps: plan.videoBps, audioBps: plan.audioBps,
                                   fps: fps, hevc: hevc, output: output, duration: duration) { f in
                progress(min((base + f) / Double(attempts), 0.99))
            }
            try await withTaskCancellationHandler { try await t.run() } onCancel: { t.cancel() }
            // FileManager y no resourceValues: este último guarda en caché el tamaño del mismo URL.
            size = ((try? FileManager.default.attributesOfItem(atPath: output.path)[.size]) as? NSNumber)?.int64Value ?? 0
            guard let limit, size > limit, attempt < attempts - 1 else { break }
            // Si bajar el bitrate ya no reduce el archivo (el codificador llegó a su piso), se reduce la resolución.
            if previous > 0, Double(size) >= Double(previous) * 0.97 {
                plan.width = max(Int(Double(plan.width) * 0.75) / 2 * 2, 2)
                plan.height = max(Int(Double(plan.height) * 0.75) / 2 * 2, 2)
            }
            previous = size
            plan.videoBps = max(plan.videoBps * Double(limit) / Double(size) * 0.9, 50_000)
        }
        progress(1)
        return CompressionReport(originalBytes: originalBytes, resultBytes: size, targetBytes: limit,
                                 reachedTarget: limit.map { size <= $0 } ?? true)
    }
}

// MARK: - Exportación de audio

private final class ExportBox: @unchecked Sendable {
    private let session: AVAssetExportSession
    init(_ s: AVAssetExportSession) { session = s }
    func cancel() { session.cancelExport() }

    func run(to url: URL, type: AVFileType, progress: @escaping @Sendable (Double) -> Void) async throws {
        session.outputURL = url
        session.outputFileType = type
        let poll = Task { [self] in
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { c.resume() }
        }
        poll.cancel()
        switch session.status {
        case .completed: progress(1)
        case .cancelled: throw CancellationError()
        default: throw CabrioError.writeFailed(session.error?.localizedDescription ?? "No se pudo crear el audio.")
        }
    }
}

// MARK: - Transcodificación de video

private final class Transcoder: @unchecked Sendable {
    struct Channel: @unchecked Sendable {
        let input: AVAssetWriterInput
        let output: AVAssetReaderOutput
        let isVideo: Bool
    }

    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private var channels: [Channel] = []
    private let duration: Double
    private let onProgress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var cancelled = false

    init(video: AVAssetTrack, audio: AVAssetTrack?, asset: AVAsset, width: Int, height: Int, videoBps: Double,
         audioBps: Double, fps: Double, hevc: Bool, output: URL, duration: Double,
         onProgress: @escaping @Sendable (Double) -> Void) throws {
        self.duration = duration
        self.onProgress = onProgress
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        } catch { throw CabrioError.writeFailed(tr("Revisa que la carpeta permita escribir.")) }
        writer.shouldOptimizeForNetworkUse = true

        var props: [String: Any] = [
            AVVideoAverageBitRateKey: Int(videoBps),
            AVVideoMaxKeyFrameIntervalKey: Int(fps * 2),
            AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
        ]
        if !hevc { props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let vSettings: [String: Any] = [
            AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: props,
        ]
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: vSettings)
        vIn.transform = video.preferredTransform
        vIn.expectsMediaDataInRealTime = false
        let vOut = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        guard reader.canAdd(vOut), writer.canAdd(vIn) else { throw CabrioError.unsupported(tr("No se pudo preparar el video.")) }
        reader.add(vOut); writer.add(vIn)
        channels.append(Channel(input: vIn, output: vOut, isVideo: true))

        if let audio {
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2, AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: Int(audioBps),
            ])
            let aOut = AVAssetReaderTrackOutput(track: audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                AVNumberOfChannelsKey: 2, AVSampleRateKey: 44_100,
            ])
            if reader.canAdd(aOut), writer.canAdd(aIn) {
                reader.add(aOut); writer.add(aIn)
                channels.append(Channel(input: aIn, output: aOut, isVideo: false))
            }
        }
    }

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func run() async throws {
        guard writer.startWriting() else { throw CabrioError.writeFailed(writer.error?.localizedDescription ?? "No se pudo crear el video.") }
        guard reader.startReading() else { writer.cancelWriting(); throw CabrioError.unreadableFile(tr("el video")) }
        writer.startSession(atSourceTime: .zero)

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let group = DispatchGroup()
            for (i, ch) in channels.enumerated() {
                group.enter()
                let queue = DispatchQueue(label: "cabrio.transcode.\(i)")
                ch.input.requestMediaDataWhenReady(on: queue) { [self] in
                    while ch.input.isReadyForMoreMediaData {
                        if isCancelled { ch.input.markAsFinished(); group.leave(); return }
                        guard let sample = ch.output.copyNextSampleBuffer() else {
                            ch.input.markAsFinished(); group.leave(); return
                        }
                        if !ch.input.append(sample) { ch.input.markAsFinished(); group.leave(); return }
                        if ch.isVideo {
                            onProgress(min(CMSampleBufferGetPresentationTimeStamp(sample).seconds / duration, 1))
                        }
                    }
                }
            }
            group.notify(queue: .global()) { cont.resume() }
        }

        if isCancelled { reader.cancelReading(); writer.cancelWriting(); throw CancellationError() }
        if reader.status == .failed {
            writer.cancelWriting()
            throw CabrioError.writeFailed(reader.error?.localizedDescription ?? "No se pudo leer el video.")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw CabrioError.writeFailed(writer.error?.localizedDescription ?? "No se pudo guardar el video.")
        }
    }
}
