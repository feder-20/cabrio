import Foundation
import CabrioApplication
import CabrioAdapters

/// Piezas compartidas por el panel, las reglas y los Ajustes: un solo historial para poder deshacer todo.
@MainActor
final class Services {
    static let shared = Services()

    let history = FileHistoryStore()
    let ruleStore = JSONRuleStore()
    let operations: RunOperation
    let ruleRunner: RuleRunner

    private init() {
        let image = ImageIOEngine()
        let fs = LocalFileSystem()
        operations = RunOperation(pdf: PDFKitEngine(), image: image, archive: ZipArchiveEngine(), media: AVFoundationEngine(),
                                  ocr: VisionOCREngine(), fileSystem: fs, history: history, suffix: { Prefs.suffix })
        ruleRunner = RuleRunner(store: ruleStore, fileSystem: fs, detector: FileKindDetector(), image: image,
                                history: history, watcher: FSEventsFolderWatcher())
    }
}
