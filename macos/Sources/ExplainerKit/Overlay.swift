import AppKit
import Observation
import SwiftUI

/// Colors and fonts of the annotations; hosts fill it from their theme.
public struct OverlayStyle: Sendable {
  public var captionBackground = Color(red: 0.055, green: 0.067, blue: 0.086).opacity(0.95)
  public var captionTitle = Color.white
  public var captionSubtitle = Color(red: 0.79, green: 0.82, blue: 0.85)
  public var highlight = Color(red: 0.30, green: 0.60, blue: 1.0)
  public var pointer = Color.white
  public var badgeBackground = Color(red: 0.106, green: 0.133, blue: 0.188).opacity(0.9)
  public var badgeText = Color.white
  public var crash = Color(red: 1, green: 0.23, blue: 0.19)
  public var spotlight = Color.black.opacity(0.45)
  public var titleFont = Font.system(size: 26, weight: .semibold)
  public var subtitleFont = Font.system(size: 16)
  public var badgeFont = Font.system(size: 17, weight: .semibold)
  public var reduceMotion = false
  public init() {}
}

/// What the annotations show right now. The runner writes it; the overlay draws it.
@MainActor @Observable
public final class OverlayModel {
  public struct Caption: Equatable, Sendable {
    public var title: String
    public var subtitle: String
    public init(title: String, subtitle: String) { self.title = title; self.subtitle = subtitle }
  }
  public struct Badge: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public var text: String
  }

  public var caption: Caption?
  public var highlights: [String] = []
  public var spotlight: String?
  public var pointer: CGPoint?  // Screen coordinates.
  public var pointerVisible = false
  public var pointerDuration = 0.6
  public var clickPulse = 0
  public var dragging = false
  public var badges: [Badge] = []
  public var stamp: String?
  public var chip: String?
  public var title = ""
  public var progress = ""

  public init() {}

  public func reset() {
    caption = nil; highlights = []; spotlight = nil; pointer = nil; pointerVisible = false
    badges = []; stamp = nil; chip = nil; progress = ""
  }

  public func badge(_ text: String) {
    let badge = Badge(text: text)
    badges.append(badge)
    if badges.count > 3 { badges.removeFirst(badges.count - 3) }
    Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(1.6))
      self?.badges.removeAll { $0.id == badge.id }
    }
  }
}

/// Covers the host window's screen with click-through annotations, so they
/// can point into any of the app's windows, and shows the runner's controls
/// in a small panel the user can click. Captions stay on the host window.
@MainActor
public final class AnnotationWindowController {
  private var overlay: NSPanel?
  private var controls: NSPanel?
  private weak var host: NSWindow?
  private var observers: [NSObjectProtocol] = []

  public init() {}

  public func show(over window: NSWindow, runner: ExplainerRunner, style: OverlayStyle, controlsView: AnyView) {
    hide()
    host = window
    let screen = window.screen ?? NSScreen.main
    let overlay = NSPanel(contentRect: screen?.frame ?? window.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    overlay.isOpaque = false
    overlay.backgroundColor = .clear
    overlay.hasShadow = false
    overlay.ignoresMouseEvents = true
    overlay.level = .floating
    overlay.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
    overlay.identifier = NSUserInterfaceItemIdentifier("explainer-overlay")
    overlay.contentView = NSHostingView(rootView: OverlayView(model: runner.overlay, style: style, window: overlay, host: window))
    overlay.orderFront(nil)
    self.overlay = overlay

    let controls = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 46), styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
    controls.isOpaque = false
    controls.backgroundColor = .clear
    controls.level = .floating
    controls.hidesOnDeactivate = false
    controls.becomesKeyOnlyIfNeeded = true
    controls.identifier = NSUserInterfaceItemIdentifier("explainer-controls")
    controls.contentView = NSHostingView(rootView: controlsView)
    controls.orderFront(nil)
    self.controls = controls
    layout()
    for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.layout() }
      })
    }
  }

  public func hide() {
    for o in observers { NotificationCenter.default.removeObserver(o) }
    observers = []
    overlay?.orderOut(nil)
    controls?.orderOut(nil)
    overlay = nil
    controls = nil
  }

  public var windows: [NSWindow] { [overlay, controls].compactMap { $0 } }

  private func layout() {
    guard let host, let overlay else { return }
    if let screen = host.screen, overlay.frame != screen.frame { overlay.setFrame(screen.frame, display: true) }
    if let controls {
      let size = controls.contentView?.fittingSize ?? NSSize(width: 420, height: 46)
      // Centered in the title bar, where it covers only the window title.
      controls.setFrame(NSRect(x: host.frame.midX - size.width / 2, y: host.frame.maxY - size.height - 4,
                               width: size.width, height: size.height), display: true)
    }
  }
}

/// The annotations. Anchor rectangles are read from the registry on every
/// frame, so highlights follow views that move or resize.
struct OverlayView: View {
  let model: OverlayModel
  let style: OverlayStyle
  weak var window: NSWindow?
  weak var host: NSWindow?

  var body: some View {
    TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
      GeometryReader { geometry in
        let size = geometry.size
        let frame = local(host?.frame, size) ?? CGRect(origin: .zero, size: size)
        ZStack {
          if let id = model.spotlight, let rect = local(AnchorRegistry.shared.screenRect(id), size) {
            style.spotlight
              .mask(Rectangle().overlay(RoundedRectangle(cornerRadius: 8).frame(width: rect.width + 16, height: rect.height + 16)
                .position(x: rect.midX, y: rect.midY).blendMode(.destinationOut)).compositingGroup())
              .transition(.opacity)
          }
          ForEach(model.highlights, id: \.self) { id in
            if let rect = local(AnchorRegistry.shared.screenRect(id), size) {
              HighlightFrame(color: style.highlight)
                .frame(width: rect.width + 10, height: rect.height + 8)
                .position(x: rect.midX, y: rect.midY)
                .transition(.opacity.combined(with: .scale(scale: 1.06)))
            }
          }
          if model.pointerVisible, let point = localPoint(model.pointer, size) {
            PointerView(color: style.pointer, pulse: model.clickPulse, dragging: model.dragging)
              .position(x: point.x + 9, y: point.y + 12)
              .animation(style.reduceMotion ? nil : .easeInOut(duration: model.pointerDuration), value: point)
          }
          ZStack {
          VStack(spacing: 12) {
            Spacer()
            HStack(spacing: 8) {
              ForEach(model.badges) { badge in
                Text(badge.text)
                  .font(style.badgeFont)
                  .foregroundStyle(style.badgeText)
                  .padding(.horizontal, 12).padding(.vertical, 6)
                  .background(style.badgeBackground, in: RoundedRectangle(cornerRadius: 9))
                  .transition(.scale(scale: 0.8).combined(with: .opacity))
              }
            }
            .animation(.spring(duration: 0.3), value: model.badges)
            if let caption = model.caption {
              CaptionCard(caption: caption, style: style)
                .frame(maxWidth: min(frame.width * 0.72, 760))
                .transition(.asymmetric(insertion: .opacity.animation(.easeOut(duration: 0.25).delay(0.12)),
                                        removal: .opacity.animation(.easeIn(duration: 0.12))))
                .id(caption.title + caption.subtitle)
            }
          }
          .padding(.bottom, max(54, frame.height * 0.08))
          .animation(.easeOut(duration: 0.35), value: model.caption)
          if let chip = model.chip {
            VStack {
              Text(chip.uppercased())
                .font(.system(size: 12, weight: .bold)).kerning(1.2)
                .foregroundStyle(style.captionTitle)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(style.highlight.opacity(0.9), in: Capsule())
                .padding(.top, 70)
              Spacer()
            }
          }
          if let stamp = model.stamp {
            Text(stamp)
              .font(.system(size: 96, weight: .black))
              .foregroundStyle(style.crash)
              .padding(.horizontal, 30)
              .overlay(RoundedRectangle(cornerRadius: 14).stroke(style.crash, lineWidth: 8))
              .rotationEffect(.degrees(-8))
              .transition(.scale(scale: 2.2).combined(with: .opacity))
          }
          }
          .frame(width: frame.width, height: frame.height)
          .position(x: frame.midX, y: frame.midY)
        }
        .frame(width: size.width, height: size.height)
        .animation(.easeInOut(duration: 0.3), value: model.highlights)
        .animation(.spring(duration: 0.35), value: model.stamp)
      }
    }
    .allowsHitTesting(false)
  }

  private func local(_ screen: CGRect?, _ size: CGSize) -> CGRect? {
    guard let screen, let window else { return nil }
    let r = window.convertFromScreen(screen)
    return CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height)
  }

  private func localPoint(_ screen: CGPoint?, _ size: CGSize) -> CGPoint? {
    guard let screen, let window else { return nil }
    let r = window.convertFromScreen(CGRect(origin: screen, size: .zero))
    return CGPoint(x: r.minX, y: size.height - r.minY)
  }
}

struct HighlightFrame: View {
  let color: Color
  @State private var glow = false
  var body: some View {
    RoundedRectangle(cornerRadius: 7)
      .stroke(color, lineWidth: 3)
      .shadow(color: color.opacity(glow ? 0.9 : 0.35), radius: glow ? 10 : 4)
      .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { glow = true } }
  }
}

struct PointerView: View {
  let color: Color
  let pulse: Int
  let dragging: Bool
  @State private var ring = false
  var body: some View {
    ZStack(alignment: .topLeading) {
      Circle()
        .stroke(Color.accentColor, lineWidth: 3)
        .frame(width: 34, height: 34)
        .scaleEffect(ring ? 1.6 : 0.4)
        .opacity(ring ? 0 : 0.9)
        .offset(x: -26, y: -29)
      Image(systemName: dragging ? "hand.point.up.left.fill" : "cursorarrow")
        .font(.system(size: 26, weight: .regular))
        .foregroundStyle(color)
        .shadow(color: .black.opacity(0.6), radius: 2, x: 1, y: 1)
    }
    .onChange(of: pulse) {
      ring = false
      withAnimation(.easeOut(duration: 0.45)) { ring = true }
    }
  }
}

struct CaptionCard: View {
  let caption: OverlayModel.Caption
  let style: OverlayStyle
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(caption.title).font(style.titleFont).foregroundStyle(style.captionTitle)
      if !caption.subtitle.isEmpty {
        Text(caption.subtitle).font(style.subtitleFont).foregroundStyle(style.captionSubtitle)
      }
    }
    .padding(.horizontal, 26).padding(.vertical, 18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(style.captionBackground, in: RoundedRectangle(cornerRadius: 18))
    .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.18), lineWidth: 1))
    .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
  }
}
