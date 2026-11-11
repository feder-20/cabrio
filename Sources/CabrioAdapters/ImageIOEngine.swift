import Foundation
import ImageIO
import Vision
import CoreImage
import UniformTypeIdentifiers
import CabrioDomain
import CabrioPorts

public struct ImageIOEngine: ImageEngine {
    public init() {}

    public func convert(_ input: URL, to format: ImageFormat, quality: Double, maxSide: Int?, output: URL) async throws {
        guard let src = CGImageSourceCreateWithURL(input as CFURL, nil) else {
            throw CabrioError.unreadableFile(input.lastPathComponent)
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide ?? 30_000,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw CabrioError.unreadableFile(input.lastPathComponent)
        }
        let type: UTType = switch format { case .jpg: .jpeg; case .png: .png; case .heic: .heic }
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
            throw CabrioError.unsupported(tr("Este Mac no puede crear archivos %@.", format.fileExtension.uppercased()))
        }
        var props: [CFString: Any] = [:]
        if format != .png { props[kCGImageDestinationLossyCompressionQuality] = quality }
        // Conserva los metadatos básicos (fecha, orientación ya aplicada por la miniatura).
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw CabrioError.writeFailed(tr("No se pudo guardar la imagen convertida."))
        }
    }

    public func removeBackground(_ input: URL, output: URL) async throws {
        let name = input.lastPathComponent
        guard let src = CGImageSourceCreateWithURL(input as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 4096,
              ] as CFDictionary) else { throw CabrioError.unreadableFile(name) }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg)
        do { try handler.perform([request]) }
        catch { throw CabrioError.unsupported(tr("No se pudo analizar «%@».", name)) }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw CabrioError.unsupported(tr("No se encontró un sujeto claro en «%@».", name))
        }
        let buffer: CVPixelBuffer
        do {
            buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler,
                                                         croppedToInstancesExtent: false)
        } catch { throw CabrioError.unsupported(tr("No se pudo separar el fondo de «%@».", name)) }
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let result = CIContext().createCGImage(ci, from: ci.extent),
              let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CabrioError.writeFailed(tr("No se pudo guardar la imagen.")) }
        CGImageDestinationAddImage(dest, result, nil)
        guard CGImageDestinationFinalize(dest) else { throw CabrioError.writeFailed(tr("No se pudo guardar la imagen.")) }
    }
}
