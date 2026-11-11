import AppKit
import SwiftUI

/// Vista transparente sobre el ícono de la barra de menú: recibe archivos arrastrados y el clic.
final class StatusDropView: NSView {
    var onDrop: ([URL]) -> Void = { _ in }
    var onClick: () -> Void = {}
    var onRightClick: () -> Void = {}

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onRightClick() } else { onClick() }
    }
    override func rightMouseDown(with event: NSEvent) { onRightClick() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDrop(urls)
        return true
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let license = LicenseController.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = Self.menuBarIcon()
            button.setAccessibilityLabel("Cabrio")
            let drop = StatusDropView(frame: button.bounds)
            drop.autoresizingMask = [.width, .height]
            drop.onClick = { [weak self] in self?.toggle() }
            drop.onRightClick = { [weak self] in self?.showMenu() }
            drop.onDrop = { [weak self] urls in
                guard let self, !self.license.isExpired else { WindowPresenter.shared.showExpired(); return }
                self.model.add(urls)
                self.show()
            }
            button.addSubview(drop)
        }
        popover.behavior = .transient
        model.onOpenSettings = { [weak self] in
            self?.popover.performClose(nil)
            WindowPresenter.shared.showSettings()
        }
        popover.contentViewController = NSHostingController(rootView: PanelView(model: model))

        // Atajo global: abre Cabrio con la selección actual del Finder.
        HotKeyCenter.shared.onPress = { [weak self] in self?.openWithFinderSelection() }
        HotKeyCenter.shared.applyPreferences()
        WindowPresenter.shared.onWelcomeFinished = { [weak self] in
            self?.presentLicenseNotices()
            self?.show()
        }
        RulesModel.shared.start()
        license.onStateChange = { state in if state == .expired { WindowPresenter.shared.showExpired() } }
        license.startRefreshing()
        if !Prefs.onboardingDone { WindowPresenter.shared.showWelcome() } else { presentLicenseNotices() }
    }

    /// Periodo terminado, aviso de primer arranque (una vez) o recordatorio diario de los últimos días.
    private func presentLicenseNotices() {
        license.refresh()
        let state = license.state
        if state == .expired { WindowPresenter.shared.showExpired(); return }
        if state == .licensed { return }
        if !license.manager.noticeSeen {
            license.manager.markNoticeSeen()
            _ = license.manager.takeDailyReminder()   // el aviso inicial ya cuenta como el de hoy
            WindowPresenter.shared.showNotice(state: state)
        } else if license.manager.takeDailyReminder() {
            WindowPresenter.shared.showNotice(state: state)
        }
    }

    /// Archivos entregados por el Finder (Acción rápida, «Abrir con», arrastrar al Dock) o por `open -a`.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return }
        // Un momento para que la app termine de arrancar si fue ella la que se lanzó con los archivos.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.model.add(files)
            self?.show()
        }
    }

    private func openWithFinderSelection() {
        do {
            let urls = try FinderSelection.current()
            if !urls.isEmpty { model.add(urls) }
            show()
        } catch {
            model.report(error.localizedDescription)
            show()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        license.refresh()
        if let info = TrialText.footer(license.state) {
            let item = menu.addItem(withTitle: info, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(withTitle: L("Obtener premium…"), action: #selector(openPurchase), keyEquivalent: "").target = self
            menu.addItem(withTitle: L("Introducir clave…"), action: #selector(openActivation), keyEquivalent: "").target = self
            menu.addItem(.separator())
        } else {
            menu.addItem(withTitle: L("Premium activado · %@", license.holder ?? ""), action: nil, keyEquivalent: "").isEnabled = false
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: L("Ajustes…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: L("Bienvenida"), action: #selector(openWelcome), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Salir de Cabrio"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        guard let button = statusItem.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func openPurchase() { license.openPurchase() }
    @objc private func openActivation() { WindowPresenter.shared.showActivation() }
    @objc private func openSettings() { WindowPresenter.shared.showSettings() }
    @objc private func openWelcome() { WindowPresenter.shared.showWelcome() }

    private static func menuBarIcon() -> NSImage? {
        // Plantilla de marca (cabrio-barra-menu-template@2x.png): macOS la tiñe según el tema.
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = true
            return img
        }
        let fallback = NSImage(systemSymbolName: "car.side", accessibilityDescription: "Cabrio")
        fallback?.isTemplate = true
        return fallback
    }

    private func toggle() {
        popover.isShown ? popover.performClose(nil) : show()
    }

    private func show() {
        license.refresh()
        if license.isExpired { WindowPresenter.shared.showExpired(); return }
        guard let button = statusItem.button, !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }
}
