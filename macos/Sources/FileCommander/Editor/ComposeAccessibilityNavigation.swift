import AppKit
import FreshKit

/// Source navigation uses AppKit's typed rotors (available before macOS 14),
/// not the currently rendered crop. A loading token identifies one item in
/// one complete generation; it never carries a guessed character or pixel.
@MainActor
final class ComposeAccessibilityNavigation: NSObject, @preconcurrency NSAccessibilityCustomRotorItemSearchDelegate, @preconcurrency NSAccessibilityElementLoading {
  weak var grid: CellGridView?
  let controller: ComposeSemanticController
  private var generation = UUID()
  private var cachedRotors: [NSAccessibilityCustomRotor] = []
  private var kinds: [ObjectIdentifier: UInt32] = [:]
  private var loaded: ComposeSemanticElement?
  private var loadedFrame = CGRect.zero
  private var lastSelection: (ordinal: Int, revision: UInt64)?

  init(grid: CellGridView) {
    self.grid = grid
    controller = .init { [weak grid] request in grid?.sendComposeIndex?(request) }
    super.init()
    controller.onChange = { [weak self] in self?.changed() }
  }

  static func owner(_ pane: ComposePresentation) -> WireComposeIndexOwner {
    owner(window: pane.identity.window, pane: pane.pane)
  }

  private static func owner(window: UInt64, pane: WirePane) -> WireComposeIndexOwner {
    .with {
      $0.window = window; $0.leaf = pane.leaf; $0.buffer = pane.buffer
      $0.epoch = pane.compose.viewport.epoch; $0.revision = pane.compose.bufferRevision
      $0.authority = pane.compose.assetAuthority; $0.document = pane.compose.assetDocument
      $0.length = pane.compose.documentLen
    }
  }

  // A previous preview may remain painted while current source or a native
  // edit awaits layout. Its semantic ranges cannot authorize navigation.
  private var currentOwner: WireComposeIndexOwner? {
    guard let grid, let displayed = grid.focusedCompose,
          displayed.layout.composition == nil, !grid.hasMarkedText(),
          grid.delegate?.grid(grid, pendingTextFor: displayed.pane)?.text == nil,
          let current = grid.store.panes.first(where: {
            $0.hasBuffer && $0.hasCompose && $0.leaf == displayed.identity.leaf && $0.buffer == displayed.identity.buffer
          }) else { return nil }
    let owner = Self.owner(window: UInt64(grid.store.windowID), pane: current)
    return owner == Self.owner(displayed) ? owner : nil
  }

  func update() {
    controller.update(owner: currentOwner, supported: grid?.delegate?.connected == true
      && grid?.delegate?.shown == true
      && grid?.store.composeSemanticIndex == true && grid?.store.composeSourceSelections == true)
    if let loaded, loaded.isAccessibilityElement() {
      let rect = loaded.accessibilityFrame()
      if rect != loadedFrame {
        loadedFrame = rect
        if let grid { NSAccessibility.post(element: grid, notification: .layoutChanged) }
      }
    }
  }

  private func changed() {
    if generation != controller.generation {
      generation = controller.generation; cachedRotors = []; kinds = [:]; loaded = nil; loadedFrame = .zero; lastSelection = nil
    }
    if let grid { NSAccessibility.post(element: grid, notification: .layoutChanged) }
  }

  func rotors() -> [NSAccessibilityCustomRotor] {
    update(); controller.activate()
    guard controller.index != nil else { return [] }
    if cachedRotors.isEmpty {
      let types: [(NSAccessibilityCustomRotor.RotorType, UInt32)] = [(.heading, 0),
        (.headingLevel1, 1), (.headingLevel2, 2), (.headingLevel3, 3), (.headingLevel4, 4),
        (.headingLevel5, 5), (.headingLevel6, 6), (.link, 16), (.image, 17)]
      for (type, kind) in types {
        let rotor = NSAccessibilityCustomRotor(rotorType: type, itemSearchDelegate: self)
        rotor.itemLoadingDelegate = self
        cachedRotors.append(rotor); kinds[ObjectIdentifier(rotor)] = kind
      }
    }
    return cachedRotors
  }

  var help: String? {
    switch controller.status {
    case .loading: return "Loading complete document navigation."
    case .failed(let message): return message
    default: return nil
    }
  }

  var loadedElement: NSAccessibilityElement? { loaded.flatMap { $0.isAccessibilityElement() ? $0 : nil } }

  // AppKit may securely archive a loading token across its accessibility
  // boundary. A connection-local generation survives that round trip without
  // retaining a separate app-owned object for every enumerated result.
  private func ordinal(_ token: Any) -> Int? {
    guard let token = token as? String, token.utf8.count <= 44, token.hasPrefix(controller.generation.uuidString + ":"),
          let ordinal = Int(token.dropFirst(37)), token == "\(controller.generation.uuidString):\(ordinal)",
          let index = controller.index, index.entries.indices.contains(ordinal),
          currentOwner == index.owner,
          grid?.delegate?.connected == true, grid?.delegate?.shown == true else { return nil }
    return ordinal
  }

  func rotor(_ rotor: NSAccessibilityCustomRotor, resultFor parameters: NSAccessibilityCustomRotor.SearchParameters) -> NSAccessibilityCustomRotor.ItemResult? {
    update()
    guard let kind = kinds[ObjectIdentifier(rotor)], let index = controller.index else { return nil }
    let current: Int?
    if let item = parameters.currentItem {
      guard let token = item.itemLoadingToken, let valid = ordinal(token) else { return nil }
      current = valid
    } else { current = nil }
    guard let found = index.find(kind: kind, after: current, forward: parameters.searchDirection == .next,
                                filter: parameters.filterString) else { return nil }
    // Search uses the full label. A menu label has an explicit shortened
    // presentation, bounded by Unicode scalars rather than one huge grapheme.
    let label = index.entries[found].label
    let prefix = String(String.UnicodeScalarView(label.unicodeScalars.prefix(512)))
    return NSAccessibilityCustomRotor.ItemResult(itemLoadingToken: "\(controller.generation.uuidString):\(found)" as NSString,
      customLabel: prefix.utf8.count < label.utf8.count ? prefix + "…" : label)
  }

  func accessibilityElement(withToken token: NSAccessibilityLoadingToken) -> (any NSAccessibilityElementProtocol)? {
    guard let ordinal = ordinal(token) else { return nil }
    let element = ComposeSemanticElement(navigation: self, generation: controller.generation, ordinal: ordinal)
    loaded = element
    // Loading follows the operator choosing this item. The normal source
    // selection queue asks Fresh to reveal it using measured viewport flow.
    _ = select(ordinal, generation: controller.generation)
    loadedFrame = element.accessibilityFrame()
    if let grid { NSAccessibility.post(element: grid, notification: .layoutChanged) }
    return element
  }

  func entry(_ ordinal: Int, generation: UUID) -> ComposeSemanticIndex.Entry? {
    guard generation == controller.generation, let index = controller.index,
          index.entries.indices.contains(ordinal), currentOwner == index.owner,
          grid?.delegate?.connected == true, grid?.delegate?.shown == true else { return nil }
    return index.entries[ordinal]
  }

  func select(_ ordinal: Int, generation: UUID) -> Bool {
    guard let entry = entry(ordinal, generation: generation), let grid,
          let pane = grid.focusedCompose, pane.pane.compose.keyboard, pane.layout.composition == nil,
          !grid.hasMarkedText(), let delegate = grid.delegate else { return false }
    let revision = pane.scope.selectionRevision
    if lastSelection?.ordinal == ordinal && lastSelection?.revision == revision { return true }
    lastSelection = (ordinal, revision)
    delegate.grid(grid, select: [entry.source], in: pane)
    return true
  }
}

@MainActor
private final class ComposeSemanticElement: NSAccessibilityElement, @preconcurrency NSAccessibilityElementProtocol {
  weak var navigation: ComposeAccessibilityNavigation?
  let generation: UUID
  let ordinal: Int
  init(navigation: ComposeAccessibilityNavigation, generation: UUID, ordinal: Int) {
    self.navigation = navigation; self.generation = generation; self.ordinal = ordinal; super.init()
  }
  private var entry: ComposeSemanticIndex.Entry? { navigation?.entry(ordinal, generation: generation) }
  override func isAccessibilityElement() -> Bool { entry != nil }
  override func accessibilityParent() -> Any? { navigation?.grid }
  override func accessibilityIdentifier() -> String { "compose-navigation-\(generation)-\(ordinal)" }
  override func accessibilityLabel() -> String? { entry?.label }
  override func accessibilityRole() -> NSAccessibility.Role? {
    guard let entry else { return nil }
    if entry.kind == 16 { return .link }
    if entry.kind == 17 { return .image }
    return .group
  }
  override func accessibilityRoleDescription() -> String? {
    entry.map { (1...6).contains($0.kind) ? "heading level \($0.kind)" : ($0.kind == 16 ? "link" : "image") }
  }
  override func accessibilityHelp() -> String? { entry == nil ? nil : "Select Markdown source" }
  override func accessibilityFrame() -> NSRect {
    guard let entry, let grid = navigation?.grid, let pane = grid.focusedCompose,
          let start = pane.layout.text.utf16Position(for: entry.source.lowerBound),
          let end = pane.layout.text.utf16Position(for: entry.source.upperBound, affinity: .upstream),
          start <= end,
          let rect = ComposeAccessibilityText(pane: pane).bounds(for: NSRange(location: start, length: end - start)) else { return .zero }
    return grid.accessibilityScreenRect(rect)
  }
  override func isAccessibilityFocused() -> Bool {
    guard let entry, let cursor = navigation?.grid?.focusedCompose?.pane.compose.cursors.first(where: \.primary), cursor.hasAnchor else { return false }
    return min(cursor.anchor, cursor.position) == UInt64(entry.source.lowerBound) && max(cursor.anchor, cursor.position) == UInt64(entry.source.upperBound)
  }
  override func setAccessibilityFocused(_ focused: Bool) { if focused { _ = accessibilityPerformPress() } }
  override func accessibilityPerformPress() -> Bool { navigation?.select(ordinal, generation: generation) ?? false }
}
