import Foundation
import CabrioDomain

/// Texto localizado. El español es la clave y el idioma base; en/pt-BR van en los .strings.
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, bundle: Localization.bundle, comment: "")
    return args.isEmpty ? format : String(format: format, arguments: args)
}

func formatBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}
