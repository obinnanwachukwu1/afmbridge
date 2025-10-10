import Foundation
import FoundationModels

// MARK: - Local JSONValue replica (subset of ChatCore internals)

private enum JSONValue: Equatable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case array([JSONValue])
  case object([String: JSONValue])
  case null
}

extension JSONValue: Codable {
  init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
      return
    }
    if let stringValue = try? container.decode(String.self) {
      self = .string(stringValue)
      return
    }
    if let boolValue = try? container.decode(Bool.self) {
      self = .bool(boolValue)
      return
    }
    if let doubleValue = try? container.decode(Double.self) {
      self = .number(doubleValue)
      return
    }
    if let arrayValue = try? container.decode([JSONValue].self) {
      self = .array(arrayValue)
      return
    }
    if let objectValue = try? container.decode([String: JSONValue].self) {
      self = .object(objectValue)
      return
    }
    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
}

extension JSONValue {
  init?(any value: Any) {
    switch value {
    case is NSNull:
      self = .null
    case let string as String:
      self = .string(string)
    case let number as NSNumber:
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        self = .bool(number.boolValue)
      } else {
        self = .number(number.doubleValue)
      }
    case let array as [Any]:
      let converted = array.compactMap { JSONValue(any: $0) }
      if converted.count == array.count {
        self = .array(converted)
      } else {
        return nil
      }
    case let dict as [String: Any]:
      var converted: [String: JSONValue] = [:]
      for (key, value) in dict {
        guard let json = JSONValue(any: value) else { return nil }
        converted[key] = json
      }
      self = .object(converted)
    default:
      return nil
    }
  }

  var stringValue: String? {
    if case let .string(value) = self { return value }
    return nil
  }

  var arrayValue: [JSONValue]? {
    if case let .array(value) = self { return value }
    return nil
  }

  var objectValue: [String: JSONValue]? {
    if case let .object(value) = self { return value }
    return nil
  }

  var doubleValue: Double? {
    switch self {
    case let .number(value): return value
    case let .string(value): return Double(value)
    case let .bool(value): return value ? 1 : 0
    default: return nil
    }
  }

  var intValue: Int? {
    if let doubleValue { return Int(doubleValue) }
    return nil
  }

  var boolValue: Bool? {
    switch self {
    case let .bool(value): return value
    case let .string(value):
      switch value.lowercased() {
      case "true", "yes", "1": return true
      case "false", "no", "0": return false
      default: return nil
      }
    default:
      return nil
    }
  }

  func toAny() -> Any {
    switch self {
    case .string(let value): return value
    case .number(let value): return value
    case .bool(let value): return value
    case .array(let value): return value.map { $0.toAny() }
    case .object(let value):
      var dict: [String: Any] = [:]
      for (key, val) in value { dict[key] = val.toAny() }
      return dict
    case .null: return NSNull()
    }
  }
}

private func prettyJSONString(from value: JSONValue) -> String? {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
  guard let data = try? encoder.encode(value) else { return nil }
  return String(data: data, encoding: .utf8)
}

// MARK: - Tool metadata replicas

private struct ToolSpec {
  struct FunctionSpec {
    let name: String
    let description: String?
    let parameters: JSONValue?
  }

  let type: String
  let function: FunctionSpec
}

private enum ToolChoice {
  case auto
  case none
  case function(String)
}

private func buildToolCatalogInstruction(toolSpecs: [ToolSpec]) -> String? {
  guard !toolSpecs.isEmpty else { return nil }
  var lines: [String] = []
  lines.append("The following functions are available for this conversation. Use them when needed to satisfy the user's request:")
  for tool in toolSpecs {
    guard tool.type == "function" else { continue }
    var entry = "- \(tool.function.name)"
    if let description = tool.function.description, !description.isEmpty {
      entry += ": \(description)"
    }
    lines.append(entry)
  }
  return lines.joined(separator: "\n")
}

private func buildToolsInstruction(toolSpecs: [ToolSpec], choice: ToolChoice?) -> String {
  if case .none? = choice {
    return "Tool calling is disabled for this request. Respond directly to the user in natural language without mentioning tools or function calls."
  }

  var lines: [String] = []
  lines.append("Decide whether a function call is required. If so, select the appropriate function and provide arguments that allow it to run successfully.")
  lines.append("Represent each decision as an entry in the tool_calls list (id, type \"function\", function name and arguments). Leave tool_calls empty when no function is needed.")
  lines.append("If the user explicitly requests a tool or function by name, or asks you to call a tool, you must include that function in tool_calls with appropriate arguments before returning.")
  lines.append("Arguments must include every required field from the schema. Do not emit empty objects or omit mandatory keys.")
  lines.append("Example tool_calls entry: [ { \"id\": \"call_read\", \"type\": \"function\", \"function\": { \"name\": \"read_file\", \"arguments\": { \"path\": \"calculator.py\" } } } ]")

  if case .function(let name)? = choice {
    lines.append("You must call the function named \(name) before returning a final answer.")
  }

  if toolSpecs.isEmpty {
    lines.append("No callable functions are available for this request.")
  } else {
    lines.append("Available functions:")
    for tool in toolSpecs {
      guard tool.type == "function" else { continue }
      let function = tool.function
      lines.append("- name: \(function.name)")
      if let description = function.description, !description.isEmpty {
        lines.append("  description: \(description)")
      }
      if let params = function.parameters, let schemaText = prettyJSONString(from: params) {
        lines.append("  parameters schema: \n\(schemaText)")
        if case let .object(dict) = params,
           let required = dict["required"]?.arrayValue,
           !required.isEmpty {
          let requiredList = required.compactMap { $0.stringValue }.joined(separator: ", ")
          lines.append("  required arguments: \(requiredList)")
        }
      }
    }
  }

  return lines.joined(separator: "\n")
}

private func canonicalJSONString(from value: JSONValue) -> String {
  let anyValue = value.toAny()
  if JSONSerialization.isValidJSONObject(anyValue),
     let data = try? JSONSerialization.data(withJSONObject: anyValue, options: []) {
    return String(data: data, encoding: .utf8) ?? "{}"
  }
  if let data = try? JSONEncoder().encode(value),
     let text = String(data: data, encoding: .utf8) {
    return text
  }
  return "{}"
}

// MARK: - Response decoding helpers

private struct ToolPlan: Decodable {
  struct Fn: Decodable {
    let name: String
    let arguments: JSONValue
  }

  struct Call: Decodable {
    let id: String?
    let type: String?
    let function: Fn
  }

  let tool_calls: [Call]
}

private struct AnyEncodable: Encodable {
  private let encodeClosure: (Encoder) throws -> Void

  init(_ wrapped: any Encodable) {
    self.encodeClosure = { encoder in try wrapped.encode(to: encoder) }
  }

  func encode(to encoder: Encoder) throws {
    try encodeClosure(encoder)
  }
}

private func renderContent(_ content: Any) -> String {
  if let enc = content as? any Encodable,
     let data = try? JSONEncoder().encode(AnyEncodable(enc)),
     let text = String(data: data, encoding: .utf8) {
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  if let string = content as? String {
    return string.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  if let dict = content as? [String: Any],
     JSONSerialization.isValidJSONObject(dict),
     let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .withoutEscapingSlashes]),
     let text = String(data: data, encoding: .utf8) {
    return text
  }

  if let array = content as? [Any],
     JSONSerialization.isValidJSONObject(array),
     let data = try? JSONSerialization.data(withJSONObject: array, options: [.prettyPrinted, .withoutEscapingSlashes]),
     let text = String(data: data, encoding: .utf8) {
    return text
  }

  return String(describing: content)
}

private func stripJSONCodeFence(_ text: String) -> String {
  var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard trimmed.hasPrefix("```") else { return trimmed }

  trimmed.removeFirst(3)
  if let newlineIndex = trimmed.firstIndex(of: "\n") {
    trimmed = String(trimmed[trimmed.index(after: newlineIndex)...])
  }

  if let fenceRange = trimmed.range(of: "```", options: .backwards) {
    trimmed = String(trimmed[..<fenceRange.lowerBound])
  }

  return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func decodeEscapedJSON(_ text: String) -> String {
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") else { return text }
  if let data = trimmed.data(using: .utf8),
     let decoded = try? JSONDecoder().decode(String.self, from: data) {
    return decoded
  }
  return text
}

// MARK: - Main entry point

@main
struct PlannerProbe {
  static func main() async {
    let toolSpecs: [ToolSpec] = [
      ToolSpec(
        type: "function",
        function: .init(
          name: "read_file",
          description: "Read the contents of a file",
          parameters: .object([
            "type": .string("object"),
            "properties": .object([
              "path": .object(["type": .string("string")])
            ]),
            "required": .array([.string("path")]),
            "additionalProperties": .bool(false)
          ])
        )
      ),
      ToolSpec(
        type: "function",
        function: .init(
          name: "apply_patch",
          description: "Apply a unified diff to a file",
          parameters: .object([
            "type": .string("object"),
            "properties": .object([
              "path": .object(["type": .string("string")]),
              "diff": .object(["type": .string("string")])
            ]),
            "required": .array([.string("path"), .string("diff")]),
            "additionalProperties": .bool(false)
          ])
        )
      ),
      ToolSpec(
        type: "function",
        function: .init(
          name: "run_tests",
          description: "Run a shell command to execute tests",
          parameters: .object([
            "type": .string("object"),
            "properties": .object([
              "command": .object(["type": .string("string")])
            ]),
            "required": .array([.string("command")]),
            "additionalProperties": .bool(false)
          ])
        )
      )
    ]

    let systemPrompt = """
You are a diligent coding agent working in a temporary repo. Keep every reply under 120 tokens and avoid chit-chat.

TOOL PROTOCOL
- Never call a tool without the required arguments. Empty {} is forbidden.
- read_file arguments MUST be exactly {"path": "calculator.py"}.
- apply_patch arguments MUST include both "path" and "diff" keys. Target calculator.py and provide a complete unified diff string.
- run_tests arguments MUST be {"command": "python -m pytest"} unless instructed otherwise.
- Follow the sequence read_file -> apply_patch -> read_file -> run_tests when appropriate.

OUTPUT FORMAT
- Respond with valid JSON containing a top-level "tool_calls" array.
- Each entry must be:
  {
    "id": "call_identifier",
    "type": "function",
    "function": {
      "name": "tool_name",
      "arguments": { ... }
    }
  }
- Arguments must include every required field with meaningful values. Do NOT leave "arguments" empty or omit keys.
- Example:
  {
    "tool_calls": [
      {
        "id": "call_read",
        "type": "function",
        "function": {
          "name": "read_file",
          "arguments": { "path": "calculator.py" }
        }
      }
    ]
  }

WORKFLOW
1. Briefly state the planned change.
2. Emit the tool_calls JSON described above with full arguments.
3. Stop after producing the JSON.
"""

    let model = SystemLanguageModel.default
    guard model.isAvailable else {
      print("System language model unavailable: \(model.availability)")
      return
    }

    let catalogInstruction = buildToolCatalogInstruction(toolSpecs: toolSpecs)
    let planningInstruction = buildToolsInstruction(toolSpecs: toolSpecs, choice: nil)
    var instructions: [String] = [systemPrompt]
    if let catalogInstruction { instructions.append(catalogInstruction) }
    instructions.append(planningInstruction)
    let joinedInstructions = instructions.joined(separator: "\n\n")

    print("=== Planning Instructions ===\n\(joinedInstructions)\n==============================")

    let session = LanguageModelSession(model: model, tools: [], instructions: joinedInstructions)

    var options = GenerationOptions()
    options.temperature = 0
    options.sampling = .greedy
    options.maximumResponseTokens = 512

    do {
      let response = try await session.respond(
        to: "We created a workspace with calculator.py. Implement factorial according to the docstring, handling non-negative ints and raising ValueError for negatives.",
        options: options
      )

      print("Raw content type: \(type(of: response.rawContent))")
      print("Parsed content type: \(type(of: response.content))")

      let rendered = renderContent(response.rawContent)
      let unescaped = decodeEscapedJSON(rendered)
      let cleaned = stripJSONCodeFence(unescaped)
      print("\n=== Rendered Content ===\n\(cleaned)\n========================")

      let data = cleaned.data(using: .utf8)
      var decodedPlan: ToolPlan? = nil
      if let data {
        decodedPlan = try? JSONDecoder().decode(ToolPlan.self, from: data)
        if decodedPlan == nil,
           let jsonObject = try? JSONSerialization.jsonObject(with: data),
           let jsonValue = JSONValue(any: jsonObject),
           case let .object(dict) = jsonValue,
           let toolCallsValue = dict["tool_calls"],
           let toolCallsData = try? JSONEncoder().encode(toolCallsValue),
           let wrapperData = "{\"tool_calls\":\(String(data: toolCallsData, encoding: .utf8) ?? "[]")}".data(using: .utf8) {
          decodedPlan = try? JSONDecoder().decode(ToolPlan.self, from: wrapperData)
        }
      }

      if let decodedPlan {
        print("\nDecoded \(decodedPlan.tool_calls.count) calls:")
        var allSatisfied = true
        for call in decodedPlan.tool_calls {
          let id = call.id ?? "<generated>"
          let type = call.type ?? "function"
          let argsValue = call.function.arguments
          let args = canonicalJSONString(from: argsValue)
          print("- id=\(id) type=\(type) name=\(call.function.name) args=\(args)")

          if let spec = toolSpecs.first(where: { $0.function.name == call.function.name }) {
            let required = spec.function.parameters?.objectValue?["required"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            let argsDict = argsValue.objectValue ?? [:]
            let missing = required.filter { argsDict[$0] == nil }
            if !missing.isEmpty {
              allSatisfied = false
              print("  ⚠️ Missing required arguments: \(missing.joined(separator: ", "))")
            }
          }
        }

        if allSatisfied {
          print("\n✅ All required arguments are present.")
        } else {
          print("\n❌ Plan is missing required arguments. Update instructions or retry.")
        }
      } else {
        print("Unable to decode ToolPlan from response")
      }
    } catch {
      print("Planning request failed: \(error)")
    }
  }
}
