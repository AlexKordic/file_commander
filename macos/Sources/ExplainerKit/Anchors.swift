import AppKit
import SwiftUI

/// Something that can locate anchors it owns, such as table rows, by ID prefix.
@MainActor
public protocol AnchorResolver: AnyObject {
  /// The anchor's rectangle in screen coordinates, or nil when it isn't visible.
  func screenRect(for id: String) -> CGRect?
  /// Does what a click on the anchor does; false when it can't.
  func perform(anchor id: String) -> Bool
}

/// Where every anchor is. Views register themselves with `.explainerAnchor(_:)`;
/// AppKit containers register resolvers for anchors they draw themselves.
@MainActor
public final class AnchorRegistry {
  public static let shared = AnchorRegistry()

  private final class WeakProbe {
    weak var view: AnchorProbeView?
    init(_ view: AnchorProbeView) { self.view = view }
  }
  private final class WeakResolver {
    weak var resolver: AnchorResolver?
    let prefix: String
    init(_ resolver: AnchorResolver, _ prefix: String) { self.resolver = resolver; self.prefix = prefix }
  }
  private var probes: [String: [WeakProbe]] = [:]
  private var resolvers: [WeakResolver] = []

  /// Rewrites host-specific aliases, such as "pane.focused" into "pane.left".
  public var alias: (String) -> String = { $0 }

  public func register(resolver: AnchorResolver, prefix: String) {
    resolvers.removeAll { $0.resolver == nil || $0.resolver === resolver && $0.prefix == prefix }
    resolvers.append(WeakResolver(resolver, prefix))
  }

  func register(_ view: AnchorProbeView, id: String) {
    var list = probes[id, default: []].filter { $0.view != nil && $0.view !== view }
    list.append(WeakProbe(view))
    probes[id] = list
  }

  func unregister(_ view: AnchorProbeView, id: String) {
    probes[id] = probes[id]?.filter { $0.view != nil && $0.view !== view }
  }

  private func probe(_ id: String) -> AnchorProbeView? {
    probes[id]?.reversed().compactMap(\.view).first { $0.window != nil && $0.isVisibleOnScreen }
  }

  private func resolver(_ id: String) -> AnchorResolver? {
    let base = id.split(separator: "[", maxSplits: 1).first.map(String.init) ?? id
    return resolvers.first { $0.resolver != nil && $0.prefix == base }?.resolver
  }

  /// The anchor's rectangle in screen coordinates.
  public func screenRect(_ rawID: String) -> CGRect? {
    let id = alias(rawID)
    if let view = probe(id) { return view.screenRect }
    return resolver(id)?.screenRect(for: id)
  }

  /// Performs the anchor's action, as a click on it would.
  @discardableResult
  public func perform(_ rawID: String) -> Bool {
    let id = alias(rawID)
    if let view = probe(id), let action = view.action {
      action()
      return true
    }
    return resolver(id)?.perform(anchor: id) ?? false
  }

  public func exists(_ rawID: String) -> Bool { screenRect(rawID) != nil }

  /// IDs of every anchor currently on screen, for checks and the anchor inspector.
  public var visibleIDs: [String] {
    probes.compactMap { id, list in list.contains { $0.view?.window != nil } ? id : nil }.sorted()
  }

  /// The value of `key` in an ID such as "pane.left.row[name=a.jpg]".
  nonisolated public static func qualifier(_ id: String, _ key: String) -> String? {
    guard let open = id.firstIndex(of: "["), id.hasSuffix("]") else { return nil }
    let body = id[id.index(after: open)..<id.index(before: id.endIndex)]
    for part in body.split(separator: ",") {
      let pair = part.split(separator: "=", maxSplits: 1)
      if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces) == key {
        return pair[1].trimmingCharacters(in: .whitespaces)
      }
    }
    return nil
  }
}

/// An invisible view that reports where its SwiftUI parent is.
final class AnchorProbeView: NSView {
  var id = "" {
    didSet {
      guard oldValue != id else { return }
      if !oldValue.isEmpty { MainActor.assumeIsolated { AnchorRegistry.shared.unregister(self, id: oldValue) } }
      if window != nil { MainActor.assumeIsolated { AnchorRegistry.shared.register(self, id: id) } }
    }
  }
  var action: (() -> Void)?
  /// The anchored view's frame in its window's content coordinates (top-left origin),
  /// measured by SwiftUI; the probe's own frame isn't reliable inside a background.
  var globalFrame: CGRect?

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    MainActor.assumeIsolated {
      if window != nil { AnchorRegistry.shared.register(self, id: id) } else { AnchorRegistry.shared.unregister(self, id: id) }
    }
  }

  var isVisibleOnScreen: Bool {
    guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor else { return false }
    return visibleRect.width > 1 && visibleRect.height > 1
  }

  var screenRect: CGRect? {
    guard let window, window.isVisible, !isHiddenOrHasHiddenAncestor else { return nil }
    if let frame = globalFrame, let content = window.contentView, frame.width > 0, frame.height > 0 {
      // SwiftUI's global space is the content view's, with the origin at the top left.
      let flipped = content.isFlipped ? frame : CGRect(x: frame.minX, y: content.bounds.height - frame.maxY, width: frame.width, height: frame.height)
      return window.convertToScreen(content.convert(flipped, to: nil))
    }
    guard isVisibleOnScreen else { return nil }
    return window.convertToScreen(convert(visibleRect, to: nil))
  }
}

struct AnchorProbe: NSViewRepresentable {
  let id: String
  let action: (() -> Void)?
  let frame: CGRect
  func makeNSView(context: Context) -> AnchorProbeView {
    let view = AnchorProbeView()
    view.id = id
    view.action = action
    view.globalFrame = frame
    return view
  }
  func updateNSView(_ view: AnchorProbeView, context: Context) {
    view.id = id
    view.action = action
    view.globalFrame = frame
  }
}

public extension View {
  /// Names this view for explainers. `action` is what a scripted click runs:
  /// the same closure a real click runs.
  func explainerAnchor(_ id: String, action: (() -> Void)? = nil) -> some View {
    background(GeometryReader { proxy in
      AnchorProbe(id: id, action: action, frame: proxy.frame(in: .global))
    })
  }
}
