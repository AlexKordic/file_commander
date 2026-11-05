import Foundation

/// Presentation geometry shared by drawing, hit testing and Fresh navigation.
/// Source Markdown and the terminal client's layout do not depend on it.
public struct ComposeTypography: Equatable {
  public var headingScales: [CGFloat]
  public var lineSpacing, paragraphSpacing, indent: CGFloat

  public init(headingScales: [CGFloat] = [1.8, 1.5, 1.25, 1.15, 1.05, 1],
              lineSpacing: CGFloat = 3, paragraphSpacing: CGFloat = 6, indent: CGFloat = 24) {
    self.headingScales = headingScales
    self.lineSpacing = lineSpacing; self.paragraphSpacing = paragraphSpacing; self.indent = indent
  }

  var isValid: Bool {
    headingScales.count == 6 && headingScales.allSatisfy { $0.isFinite && $0 > 0 }
      && [lineSpacing, paragraphSpacing, indent].allSatisfy { $0.isFinite && $0 >= 0 }
  }
}
