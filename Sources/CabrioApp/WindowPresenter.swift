import AppKit
import SwiftUI
import CabrioDomain

/// Abre las ventanas de Ajustes y Bienvenida. Cabrio es una app de barra de menú: hay que activarla a mano.
@MainActor
final class WindowPresenter {
    static let shared = WindowPresenter()
    var onWelcomeFinished: () -> Void = {}
    private var settings: NSWindow?
    private var welcome: NSWindow?
    private var notice: NSWindow?
    private var activation: NSWindow?
    private var expired: NSWindow?

    func showSettings() {
        if settings == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = L("Ajustes de Cabrio")
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settings = w
        }
        present(settings!)
    }

    func showWelcome() {
        if welcome == nil {
            let view = WelcomeView { [weak self] in
                Prefs.onboardingDone = true
                self?.welcome?.close()
                self?.onWelcomeFinished()
            }
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = L("Bienvenido a Cabrio")
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            welcome = w
        }
        present(welcome!)
    }

    /// Aviso de prueba (primer arranque o recordatorio diario).
    func showNotice(state: TrialState) {
        notice?.close()
        let view = TrialNoticeView(state: state, trialEnd: LicenseController.shared.trialEnd, onOK: { [weak self] in self?.notice?.close() },
                                   onMore: { [weak self] in LicenseController.shared.openPurchase(); self?.notice?.close() })
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = L("Versión de prueba")
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        notice = w
        present(w)
    }

    /// Introducir clave (versión de prueba en curso).
    func showActivation() {
        if LicenseController.shared.isExpired { showExpired(); return }
        if activation == nil {
            let view = ActivationView(license: LicenseController.shared, expired: false) { [weak self] in self?.activation?.close() }
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = L("Licencia de Cabrio")
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            activation = w
        }
        present(activation!)
    }

    /// Periodo terminado: ventana propia que no se cierra; solo se sale activando o con «Salir».
    func showExpired() {
        if expired == nil {
            let view = ActivationView(license: LicenseController.shared, expired: true) { [weak self] in
                self?.expired?.close(); self?.expired = nil
            }
            let w = UncloseableWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "Cabrio"
            w.styleMask = [.titled]
            w.level = .floating
            w.isReleasedWhenClosed = false
            w.center()
            expired = w
        }
        present(expired!)
    }

    private func present(_ w: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
