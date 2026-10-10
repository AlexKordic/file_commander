import Foundation

/// Any JSON value; explainer steps carry host-specific arguments in these.
public enum JSONValue: Codable, Hashable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null }
    else if let b = try? c.decode(Bool.self) { self = .bool(b) }
    else if let n = try? c.decode(Double.self) { self = .number(n) }
    else if let s = try? c.decode(String.self) { self = .string(s) }
    else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
    else { self = .object(try c.decode([String: JSONValue].self)) }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let b): try c.encode(b)
    case .number(let n): try c.encode(n)
    case .string(let s): try c.encode(s)
    case .array(let a): try c.encode(a)
    case .object(let o): try c.encode(o)
    }
  }

  public var string: String? { if case .string(let s) = self { return s }; return nil }
  public var number: Double? { if case .number(let n) = self { return n }; return nil }
  public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
  public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
  public var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
  public subscript(key: String) -> JSONValue? { object?[key] }
  public var strings: [String] {
    if let s = string { return [s] }
    return array?.compactMap(\.string) ?? []
  }
}

/// One step: a single action key with its value, plus options such as hold or timeout.
public struct ExplainerStep: Codable, Hashable, Sendable {
  public var action: String
  public var value: JSONValue
  public var options: [String: JSONValue]

  static let optionKeys: Set<String> = ["hold", "timeout", "gap", "ms", "as_job", "sub", "nth", "approach_ms", "speed", "note"]

  public init(action: String, value: JSONValue, options: [String: JSONValue] = [:]) {
    self.action = action
    self.value = value
    self.options = options
  }

  public init(from decoder: Decoder) throws {
    let object = try decoder.singleValueContainer().decode([String: JSONValue].self)
    let actions = object.keys.filter { !ExplainerStep.optionKeys.contains($0) }
    guard actions.count == 1, let action = actions.first else {
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                              debugDescription: "A step needs exactly one action, found \(actions.sorted())"))
    }
    self.action = action
    value = object[action]!
    options = object.filter { $0.key != action }
  }

  public func encode(to encoder: Encoder) throws {
    var object = options
    object[action] = value
    var c = encoder.singleValueContainer()
    try c.encode(object)
  }

  public func option(_ key: String) -> JSONValue? { options[key] }
  public var hold: Double { (options["hold"]?.number ?? 0) / 1000 }
  public var timeout: Double { options["timeout"]?.number ?? 15 }
}

public struct ExplainerScript: Codable, Hashable, Sendable, Identifiable {
  public struct Covers: Codable, Hashable, Sendable {
    public var commands: [String] = []
    public var anchors: [String] = []
    public init() {}
    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      commands = try c.decodeIfPresent([String].self, forKey: .commands) ?? []
      anchors = try c.decodeIfPresent([String].self, forKey: .anchors) ?? []
    }
  }
  public var id: String
  public var title: String
  public var summary: String
  public var chapter: String
  public var order: Int
  public var duration: Int = 60
  public var covers = Covers()
  public var needs: [String: JSONValue] = [:]
  public var steps: [ExplainerStep]

  public func needs(_ key: String) -> Bool { needs[key]?.bool ?? false }

  enum CodingKeys: String, CodingKey { case id, title, summary, chapter, order, duration, covers, needs, steps }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    title = try c.decode(String.self, forKey: .title)
    summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
    chapter = try c.decodeIfPresent(String.self, forKey: .chapter) ?? "basics"
    order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
    duration = try c.decodeIfPresent(Int.self, forKey: .duration) ?? 60
    covers = try c.decodeIfPresent(Covers.self, forKey: .covers) ?? Covers()
    needs = try c.decodeIfPresent([String: JSONValue].self, forKey: .needs) ?? [:]
    steps = try c.decode([ExplainerStep].self, forKey: .steps)
  }
}

public struct ExplainerChapter: Codable, Hashable, Sendable, Identifiable {
  public var id: String
  public var title: String
  public var recap: String = ""
  enum CodingKeys: String, CodingKey { case id, title, recap }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    title = try c.decode(String.self, forKey: .title)
    recap = try c.decodeIfPresent(String.self, forKey: .recap) ?? ""
  }
}

/// Every explainer and chapter of a host, loaded from a folder of JSON files.
public struct ExplainerCatalog: Sendable {
  public var chapters: [ExplainerChapter]
  public var scripts: [ExplainerScript]

  public init(chapters: [ExplainerChapter], scripts: [ExplainerScript]) {
    self.chapters = chapters
    self.scripts = scripts.sorted { $0.order < $1.order }
  }

  /// Loads chapters.json and every other *.json in `folder`.
  public static func load(from folder: URL) throws -> ExplainerCatalog {
    let decoder = JSONDecoder()
    let chapters = try decoder.decode([ExplainerChapter].self, from: Data(contentsOf: folder.appendingPathComponent("chapters.json")))
    var scripts: [ExplainerScript] = []
    for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    where file.pathExtension == "json" && file.lastPathComponent != "chapters.json" {
      do {
        scripts.append(try decoder.decode(ExplainerScript.self, from: Data(contentsOf: file)))
      } catch {
        throw NSError(domain: "ExplainerKit", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(file.lastPathComponent): \(error)"])
      }
    }
    return ExplainerCatalog(chapters: chapters, scripts: scripts)
  }

  public func script(_ id: String) -> ExplainerScript? { scripts.first { $0.id == id } }
  public func scripts(in chapter: String) -> [ExplainerScript] { scripts.filter { $0.chapter == chapter } }
  public var totalDuration: Int { scripts.reduce(0) { $0 + $1.duration } }
}
