import Foundation
import CabrioDomain
import CabrioPorts

/// Calcula, sin tocar nada, a qué nombre pasaría cada archivo. Sirve también para la vista previa.
public struct RenamePlanner: Sendable {
    private let fs: FileSystem
    public init(fileSystem: FileSystem) { fs = fileSystem }

    public func plan(_ inputs: [URL], spec: RenameSpec) throws -> [FileMove] {
        guard !inputs.isEmpty else { throw CabrioError.notEnoughFiles }
        let items = inputs.map { ($0, fs.attributes(of: $0)) }
        let ordered = spec.sortByDate
            ? items.sorted { ($0.1.modified ?? .distantPast, $0.0.lastPathComponent) < ($1.1.modified ?? .distantPast, $1.0.lastPathComponent) }
            : items.sorted { $0.0.lastPathComponent.localizedStandardCompare($1.0.lastPathComponent) == .orderedAscending }

        let sources = Set(inputs.map { $0.path.lowercased() })
        var taken = Set<String>()        // destinos ya reservados en este lote (sin distinguir mayúsculas, como APFS)
        var moves: [FileMove] = []

        for (index, (url, attrs)) in ordered.enumerated() {
            let ext = attrs.isDirectory ? "" : url.pathExtension
            var base = attrs.isDirectory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
            if !spec.find.isEmpty { base = base.replacingOccurrences(of: spec.find, with: spec.replaceWith) }
            var name = try RenameTemplate.render(spec.template, name: base, parent: url.deletingLastPathComponent().lastPathComponent,
                                                 index: index, start: spec.start, created: attrs.created, modified: attrs.modified)
            switch spec.caseStyle {
            case .keep: break
            case .lower: name = name.lowercased()
            case .upper: name = name.uppercased()
            case .title: name = name.capitalized
            }
            name = try RenameTemplate.sanitize(name)

            let dir = url.deletingLastPathComponent()
            let free = OutputNaming.firstFree(base: name, suffix: "", ext: ext) { candidate in
                let target = dir.appendingPathComponent(candidate)
                let key = target.path.lowercased()
                if taken.contains(key) { return true }
                // Existe y no es uno de los archivos que se están renombrando.
                return fs.exists(target) && !sources.contains(key)
            }
            let target = dir.appendingPathComponent(free)
            taken.insert(target.path.lowercased())
            if target.path != url.path { moves.append(FileMove(from: url, to: target)) }
        }
        return moves
    }
}
