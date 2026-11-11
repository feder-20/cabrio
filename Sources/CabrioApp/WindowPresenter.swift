import AppKit
import SwiftUI

/// Abre las ventanas de Ajustes y Bienvenida. Cabrio es una app de barra de menú: hay que activarla a mano.
@MainActor
final class WindowPresenter {
    static let shared = WindowPresenter()
    var onWelcomeFinished: () -> Void = {}
    private var settings: NSWindow?
    private var welcome: NSWindow?

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

    private func present(_ w: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
