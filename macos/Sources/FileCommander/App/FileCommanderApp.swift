import AppKit
import ExplainerKit
import FCKit
import SwiftUI

@main
struct FileCommanderApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  private let app = AppController.shared

  init() {
    AppController.shared.start(arguments: Array(CommandLine.arguments.dropFirst()))
  }

  var body: some Scene {
    Window("File Commander", id: "main") {
      MainWindow()
        .environment(app)
        .frame(minWidth: 820, minHeight: 480)
    }
    .defaultSize(width: 1240, height: 780)
    .commands { AppCommands(app: app) }

    Window("Activity", id: "activity") {
      ActivityWindow().environment(app)
    }
    .defaultSize(width: 820, height: 480)

    Window("Errors", id: "errors") {
      ErrorsWindow().environment(app)
    }
    .defaultSize(width: 640, height: 360)

    Window("Find", id: "find") {
      FindWindow().environment(app)
    }
    .defaultSize(width: 680, height: 520)

    Settings {
      SettingsView().environment(app)
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    MainActor.assumeIsolated {
      let app = AppController.shared
      app.applyAppearance()
      let arguments = CommandLine.arguments
      if let index = arguments.firstIndex(of: "--record-session"), index + 1 < arguments.count {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
          app.tutorial.recordTake(configuration: URL(fileURLWithPath: arguments[index + 1]))
        }
      }
      if let index = arguments.firstIndex(of: "--run-explainer"), index + 1 < arguments.count {
        app.tutorial.quitWhenDone = true
        if let speed = arguments.firstIndex(of: "--speed").flatMap({ $0 + 1 < arguments.count ? Double(arguments[$0 + 1]) : nil }) {
          app.preferences.tutorialSpeed = speed
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { app.tutorial.start(arguments[index + 1]) }
      }
      if let index = arguments.firstIndex(of: "--export-explainer"), index + 1 < arguments.count {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { app.tutorial.export(arguments[index + 1], arguments: arguments) }
      }
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    MainActor.assumeIsolated { AppController.shared.stop() }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
