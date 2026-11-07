import Foundation
import CoreText
import Darwin
import FreshKit
import CryptoKit

func milliseconds<T>(_ work: () throws -> T) rethrows -> (T, Double) {
  let start = ProcessInfo.processInfo.systemUptime
  let result = try work()
  return (result, (ProcessInfo.processInfo.systemUptime - start) * 1000)
}

func peakRSS() -> Int64 {
  var usage = rusage()
  return getrusage(RUSAGE_SELF, &usage) == 0 ? Int64(usage.ru_maxrss) : 0
}

enum ProfileFailure: Error { case arguments, layout(String), noFixtures }

/// An opt-in comparison artifact, outside all layout timing regions. Includes
/// glyphs and global indices so a faster run cannot silently change shaping.
func geometry(_ layout: ComposePaneLayout) throws -> Data {
  func rect(_ value: CGRect) -> [Double] {
    [Double(value.minX), Double(value.minY), Double(value.width), Double(value.height)]
  }
  let fragments: [[String: Any]] = layout.text.fragments.map { fragment in
    let runs: [[String: Any]] = (CTLineGetGlyphRuns(fragment.line) as! [CTRun]).map { run in
      let count = CTRunGetGlyphCount(run)
      let indices = fragment.shaped.indices(of:run)
      var glyphs = [CGGlyph](repeating: 0, count: count)
      var positions = [CGPoint](repeating: .zero, count: count)
      CTRunGetGlyphs(run, CFRange(), &glyphs)
      CTRunGetPositions(run, CFRange(), &positions)
      let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
      return ["font": CTFontCopyPostScriptName(font) as String, "font_size": CTFontGetSize(font),
        "traits": CTFontGetSymbolicTraits(font).rawValue, "indices": indices, "glyphs": glyphs,
        "positions": positions.map { [Double($0.x), Double($0.y)] }]
    }
    var value: [String: Any] = ["range": [fragment.range.location, fragment.range.length], "rect": rect(fragment.rect),
      "baseline": fragment.baseline, "content_end": fragment.contentEnd, "runs": runs]
    if let table = fragment.table {
      value["table"] = [table.table, table.row.lowerBound, table.row.upperBound, table.column ?? -1,
        table.source.lowerBound, table.source.upperBound]
    }
    return value
  }
  let tables: [[String: Any]] = layout.text.tables.map { table in
    ["source": [table.source.lowerBound, table.source.upperBound], "rect": rect(table.rect), "columns": table.columns,
      "rows": table.rows.map { row -> [String: Any] in
        ["source": [row.source.lowerBound, row.source.upperBound], "content_end": row.contentEnd, "rect": rect(row.rect),
          "header": row.header, "raw": row.raw, "cells": row.cells.map { cell -> [String: Any] in
            var value: [String: Any] = ["rect": rect(cell.rect), "content": rect(cell.content), "column": cell.column]
            if let source = cell.source { value["source"] = [source.lowerBound, source.upperBound] }
            if let display = cell.display { value["display"] = [display.location, display.length] }
            return value
          }]
      }]
  }
  let attachments: [[String: Any]] = layout.text.attachments.map { placed in
    ["source": [placed.attachment.source.lowerBound, placed.attachment.source.upperBound],
      "display": [placed.attachment.display.lowerBound, placed.attachment.display.upperBound],
      "preview": placed.attachment.preview, "rect": rect(placed.rect)]
  }
  return try JSONSerialization.data(withJSONObject: ["text": layout.text.projection.text,
    "source": [layout.text.projection.source.lowerBound, layout.text.projection.source.upperBound],
    "size": [Double(layout.text.size.width), Double(layout.text.size.height)],
    "fragments": fragments, "tables": tables, "attachments": attachments], options: [.sortedKeys])
}

func profile() throws {
  let args = CommandLine.arguments
  guard args.count == 3 else { throw ProfileFailure.arguments }
  let input = URL(fileURLWithPath: args[1], isDirectory: true), output = URL(fileURLWithPath: args[2])
  let files = try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "pb" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
  guard !files.isEmpty else { throw ProfileFailure.noFixtures }
  let body = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
  let code = CTFontCreateWithName("Menlo" as CFString, 18, nil)
  var records: [[String: Any]] = []
  for file in files {
    let bytes = try Data(contentsOf: file), name = file.deletingPathExtension().lastPathComponent
    var decode: [Double] = [], cold: [Double] = [], retained: [Double] = [], multiple: [Double] = []
    var resized: [Double] = [], returned: [Double] = []
    var sharedMultiple: [Double] = []
    var freshContextMS: [Double] = [], selectedContextMS: [Double] = []
    var contextBytes = 0
    var baseline: ComposePaneLayout?
    for iteration in 0..<3 {
      try autoreleasepool {
        let (pane, decodeMS) = try milliseconds { try WireComposePane(serializedBytes: bytes) }
        if pane.hasTextContext {
          guard let prior = ComposeTextContext(pane.textContext, documentLength: pane.documentLen) else {
            throw ProfileFailure.layout("\(name): invalid raw text context")
          }
          // Separately delivered messages own separate string storage. Decode
          // outside the timed region instead of measuring pointer identity.
          var wire = try WireComposeTextContext(serializedBytes: pane.textContext.serializedData())
          wire.selectionStart = wire.utf16Start + UInt64(wire.text.unicodeScalars.first?.utf16.count ?? 0)
          wire.selectionEnd = wire.selectionStart
          var fresh: ComposeTextContext?, selected: ComposeTextContext?
          var freshMS = 0.0, selectedMS = 0.0
          func create() { (fresh, freshMS) = milliseconds { ComposeTextContext(wire, documentLength: pane.documentLen) } }
          func select() { (selected, selectedMS) = milliseconds { ComposeTextContext(wire, documentLength: pane.documentLen, reuse: prior) } }
          if iteration % 2 == 0 { create(); select() } else { select(); create() }
          guard let fresh, let selected, fresh.selection == selected.selection, fresh.source == selected.source,
                fresh.range == selected.range, fresh.text.utf8.elementsEqual(selected.text.utf8),
                fresh.sourceRange(forUTF16: fresh.selection) == selected.sourceRange(forUTF16: selected.selection) else {
            throw ProfileFailure.layout("\(name): selection reuse changed raw context coordinates")
          }
          freshContextMS.append(freshMS); selectedContextMS.append(selectedMS); contextBytes = wire.text.utf8.count
        }
        let (layout, coldMS) = milliseconds { ComposePaneLayout(pane: pane, body: body, monospace: code, width: 960) }
        guard let layout else { throw ProfileFailure.layout(name) }
        let (warm, retainedMS) = milliseconds { ComposePaneLayout(pane: pane, body: body, monospace: code, width: 960, reuse: layout) }
        guard warm?.text === layout.text else { throw ProfileFailure.layout("\(name): unchanged input did not reuse measured layout") }
        let (narrow, resizedMS) = milliseconds { ComposePaneLayout(pane: pane, body: body, monospace: code, width: 640, reuse: layout) }
        guard let narrow else { throw ProfileFailure.layout("\(name): resize failed") }
        let (restored, returnedMS) = milliseconds { ComposePaneLayout(pane: pane, body: body, monospace: code, width: 960, reuse: narrow) }
        guard let restored, restored.text.fragments.count == layout.text.fragments.count,
              restored.text.tables.map(\.columns) == layout.text.tables.map(\.columns) else {
          throw ProfileFailure.layout("\(name): returning to the same width changed the geometry")
        }
        let widths = [CGFloat(480), 640, 960, 480]
        // Distinct decodes model separately delivered split panes; shared
        // inputs must compare by content rather than protobuf storage identity.
        let inputs = try widths.map { _ in try WireComposePane(serializedBytes: bytes) }
        let (independent, multipleMS) = try milliseconds {
          let panes = try zip(inputs, widths).map { input, width in
            guard let value = ComposePaneLayout(pane: input, body: body, monospace: code, width: width) else { throw ProfileFailure.layout(name) }
            return value
          }
          // Retain all four layouts at once, as independent editor splits do.
          precondition(panes.reduce(0) { $0 + $1.text.fragments.count } > 0)
          return panes
        }
        let (shared, sharedMS) = try milliseconds {
          var panes: [ComposePaneLayout] = []
          for (input, width) in zip(inputs, widths) {
            guard let value = ComposePaneLayout(pane: input, body: body, monospace: code, width: width,
              sharingMeasurementsWith: panes) else { throw ProfileFailure.layout(name) }
            panes.append(value)
          }
          return panes
        }
        // Geometry comparison stays outside the timed construction. The first
        // shared pane has no previous provider: this includes its cold cost.
        guard zip(independent, shared).allSatisfy({ a, b in
          a.text.fragments.map(\.range) == b.text.fragments.map(\.range)
            && a.text.fragments.map(\.rect) == b.text.fragments.map(\.rect)
            && a.text.tables.map(\.columns) == b.text.tables.map(\.columns)
        }) else {
          throw ProfileFailure.layout("\(name): sharing changed split geometry")
        }
        decode.append(decodeMS); cold.append(coldMS); retained.append(retainedMS); multiple.append(multipleMS)
        resized.append(resizedMS); returned.append(returnedMS)
        sharedMultiple.append(sharedMS)
        baseline = layout
      }
    }
    let layout = baseline!
    let rss = peakRSS()
    var record: [String: Any] = [
      "case": name, "pane_bytes": bytes.count, "projection_bytes": layout.text.projection.text.utf8.count,
      "fragments": layout.text.fragments.count, "attachments": layout.text.attachments.count, "tables": layout.text.tables.count,
      "decode_ms": decode, "cold_layout_ms": cold, "retained_layout_ms": retained, "four_panes_ms": multiple,
      "resized_layout_ms": resized, "returned_layout_ms": returned,
      "shared_four_panes_ms": sharedMultiple,
      "raw_context_bytes": contextBytes, "fresh_text_context_ms": freshContextMS, "reselected_text_context_ms": selectedContextMS,
      "process_peak_rss_bytes": rss,
    ]
    if ProcessInfo.processInfo.environment["FC_COMPOSE_PROFILE_GEOMETRY"] == "1" {
      let data = try geometry(layout)
      let artifact = output.deletingPathExtension().lastPathComponent + "-" + name + ".geometry.json"
      try data.write(to: output.deletingLastPathComponent().appendingPathComponent(artifact), options: .atomic)
      record["geometry_artifact"] = artifact
      record["geometry_sha256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    records.append(record)
  }
  #if DEBUG
  let configuration = "debug"
  #else
  let configuration = "release"
  #endif
  let report: [String: Any] = [
    "profile": configuration,
    "scope": "protobuf decode, raw text-service context and measured native layout; excludes plugin formatting, image I/O/decode, drawing and input-to-paint latency",
    "rss_scope": "process high-water mark since start, including prior cases",
    "body_font": "Helvetica 18", "code_font": "Menlo 18", "width_points": 960,
    "cases": records,
  ]
  let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
  try data.write(to: output, options: .atomic)
  print(String(decoding: data, as: UTF8.self))
}

do {
  let args = CommandLine.arguments
  if args.count == 4, args[1] == "--memory" {
    try profileMemory(input: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3]))
  } else { try profile() }
}
catch {
  FileHandle.standardError.write(Data("Compose resource profile failed: \(error)\nUsage: fc-compose-profile INPUT_DIRECTORY OUTPUT_JSON\n       fc-compose-profile --memory INPUT_PB OUTPUT_JSON\n".utf8))
  exit(1)
}
