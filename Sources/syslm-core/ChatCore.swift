// syslm-core/ChatCore.swfit

import Foundation
import FoundationModels

public enum ChatEngineError: Error, CustomStringConvertible {
  case emptyMessages
  case modelUnavailable(String)
  case lastMessageNotUser
  case invalidToolChoice(String)
  case invalidSchema(String)
  case streamingUnsupported(String)
  case invalidMessage(String)

  public var description: String {
    switch self {
    case .emptyMessages:
      return "messages[] is empty"
    case .modelUnavailable(let reason):
      return "SystemLanguageModel is unavailable: \(reason)"
    case .lastMessageNotUser:
      return "last message must be { role: \"user\", ... } so the model can reply"
    case .invalidToolChoice(let name):
      return "tool_choice requested function \(name) but it was not provided in tools[]"
    case .invalidSchema(let reason):
      return "response_format.json_schema is invalid: \(reason)"
    case .streamingUnsupported(let reason):
      return "streaming is not supported for this request: \(reason)"
    case .invalidMessage(let reason):
      return "messages entry is invalid: \(reason)"
    }
  }
}

public struct Message: Decodable {
  public enum Role: String, Decodable { case system, user, assistant, tool }

  public struct ToolCall: Decodable {
    public struct FunctionCall: Decodable {
      public let name: String
      public let arguments: String?
    }

    public let id: String?
    public let type: String?
    public let function: FunctionCall
  }

  public let role: Role
  public let content: String?
  public let toolCalls: [ToolCall]?
  public let toolCallId: String?
  public let name: String?

  enum CodingKeys: String, CodingKey {
    case role
    case content
    case toolCalls = "tool_calls"
    case toolCallId = "tool_call_id"
    case name
  }
}

public struct InputPayload: Decodable {
  public let model: String?
  public let messages: [Message]
  public let temperature: Double?
  public let topK: Int?
  public let maxOutputTokens: Int?
  public let responseFormat: ResponseFormat?
  public let tools: [ToolSpec]?
  public let toolChoice: ToolChoice?
  public let stream: Bool?

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.model = try c.decodeIfPresent(String.self, forKey: .model)
    self.messages = try c.decode([Message].self, forKey: .messages)

    var temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
    if temperature == nil {
      temperature = try c.decodeIfPresent(Double.self, forKey: .temperatureAlt)
    }
    self.temperature = temperature

    var topK = try c.decodeIfPresent(Int.self, forKey: .topK)
    if topK == nil {
      topK = try c.decodeIfPresent(Int.self, forKey: .topKAlt)
    }
    self.topK = topK

    var maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
    if maxTokens == nil {
      maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxOutputTokensAlt)
    }
    if maxTokens == nil {
      maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens)
    }
    if maxTokens == nil {
      maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokensAlt)
    }
    self.maxOutputTokens = maxTokens

    self.responseFormat = try c.decodeIfPresent(ResponseFormat.self, forKey: .responseFormat)
    self.tools = try c.decodeIfPresent([ToolSpec].self, forKey: .tools)
    self.toolChoice = try c.decodeIfPresent(ToolChoice.self, forKey: .toolChoice)
    self.stream = try c.decodeIfPresent(Bool.self, forKey: .stream)
  }

  enum CodingKeys: String, CodingKey {
    case model
    case messages
    case temperature
    case temperatureAlt = "temp"
    case topK
    case topKAlt = "top_k"
    case maxOutputTokens
    case maxOutputTokensAlt = "max_output_tokens"
    case maxTokens = "maxTokens"
    case maxTokensAlt = "max_tokens"
    case responseFormat = "response_format"
    case tools
    case toolChoice = "tool_choice"
    case stream
  }

  public struct ResponseFormat: Decodable {
    public enum FormatType: String, Decodable { case jsonSchema = "json_schema" }

    public let type: FormatType
    public let jsonSchema: JSONSchemaPayload?

    private enum CodingKeys: String, CodingKey {
      case type
      case jsonSchema = "json_schema"
    }

    public struct JSONSchemaPayload: Decodable {
      public let name: String
      public let description: String?
      public let schema: JSONValue
      public let strict: Bool?
    }
  }

  public struct ToolSpec: Decodable {
    public let type: String
    public let function: FunctionSpec

    public struct FunctionSpec: Decodable {
      public let name: String
      public let description: String?
      public let parameters: JSONValue?
    }
  }

  public enum ToolChoice: Decodable {
    case auto
    case none
    case function(name: String)

    public init(from decoder: any Decoder) throws {
      if let container = try? decoder.singleValueContainer(), container.decodeNil() {
        self = .auto
        return
      }

      let container = try decoder.singleValueContainer()
      if let stringValue = try? container.decode(String.self) {
        switch stringValue.lowercased() {
        case "auto": self = .auto
        case "none": self = .none
        default:
          throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported tool_choice string: \(stringValue)")
        }
        return
      }

      let object = try container.decode([String: JSONValue].self)
      guard let typeValue = object["type"], case let .string(typeString) = typeValue else {
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "tool_choice object missing type")
      }

      switch typeString.lowercased() {
      case "auto":
        self = .auto
      case "none":
        self = .none
      case "function":
        guard let functionValue = object["function"], case let .object(functionObject) = functionValue,
              let nameValue = functionObject["name"], case let .string(name) = nameValue else {
          throw DecodingError.dataCorruptedError(in: container, debugDescription: "tool_choice.function missing name")
        }
        self = .function(name: name)
      default:
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported tool_choice type: \(typeString)")
      }
    }
  }
}

private struct PreparedSession {
  let lastMessage: Message
  let declaredToolSpecs: [InputPayload.ToolSpec]
  let generationSchema: GenerationSchema?
  let options: GenerationOptions
  let warnings: [String]
  let promptContent: String
  let toolChoice: InputPayload.ToolChoice?
  let effectiveToolChoice: InputPayload.ToolChoice?
  let systemModel: SystemLanguageModel
  let baseInstructions: [String]
  let historyMessages: [Message]
}

public enum JSONValue: Equatable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case array([JSONValue])
  case object([String: JSONValue])
  case null
}

extension JSONValue: Codable {
  public init(from decoder: any Decoder) throws {
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

  public func encode(to encoder: any Encoder) throws {
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
        guard let jsonValue = JSONValue(any: value) else { return nil }
        converted[key] = jsonValue
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

  var doubleValue: Double? {
    switch self {
    case let .number(value): return value
    case let .string(value): return Double(value)
    case let .bool(value): return value ? 1 : 0
    default: return nil
    }
  }

  var intValue: Int? {
    if let double = doubleValue { return Int(double) }
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

  var arrayValue: [JSONValue]? {
    if case let .array(value) = self { return value }
    return nil
  }

  var objectValue: [String: JSONValue]? {
    if case let .object(value) = self { return value }
    return nil
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

func prettyJSONString(from value: JSONValue) -> String? {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
  guard let data = try? encoder.encode(value) else { return nil }
  return String(data: data, encoding: .utf8)
}

enum SchemaConversionError: Error, CustomStringConvertible {
  case unsupportedSchema(String)
  case missingKey(String)

  var description: String {
    switch self {
    case .unsupportedSchema(let message):
      return "Unsupported schema: \(message)"
    case .missingKey(let key):
      return "Schema missing required key: \(key)"
    }
  }
}

func normalizeJSONSchema(
  name: String,
  description: String?,
  schema: JSONValue
) throws -> JSONValue {
  try normalizeSchema(name: name, description: description, schema: schema, preferredTitle: name)
}

private func normalizeSchema(
  name: String,
  description: String?,
  schema: JSONValue,
  preferredTitle: String
) throws -> JSONValue {
  guard let dict = schema.objectValue else {
    throw SchemaConversionError.unsupportedSchema("Expected JSON object for schema \(preferredTitle)")
  }

  let explicitType = dict["type"]?.stringValue?.lowercased()
  if let explicitType {
    let allowed = ["object", "array", "string", "integer", "number", "boolean"]
    if !allowed.contains(explicitType) {
      fputs("[syslm-core] Unsupported schema type: \(explicitType) for \(preferredTitle)\n", stderr)
      throw SchemaConversionError.unsupportedSchema("Type \(explicitType) for \(preferredTitle) is not supported")
    }
  }
  let resolvedType: String
  if let explicitType {
    resolvedType = explicitType
  } else if dict["properties"] != nil {
    resolvedType = "object"
  } else if dict["items"] != nil {
    resolvedType = "array"
  } else if dict["enum"] != nil {
    resolvedType = "string"
  } else {
    throw SchemaConversionError.unsupportedSchema("Unable to infer schema type for \(preferredTitle)")
  }

  switch resolvedType {
  case "object":
    let propertiesValue = dict["properties"]?.objectValue ?? [:]
    var normalizedProps: [String: JSONValue] = [:]
    for (key, value) in propertiesValue {
      let propertyTitle = "\(preferredTitle).\(key)"
      normalizedProps[key] = try normalizeSchema(name: key, description: nil, schema: value, preferredTitle: propertyTitle)
    }

    let requiredNames = dict["required"]?.arrayValue?.compactMap { $0.stringValue } ?? Array(propertiesValue.keys)
    let additionalProperties = dict["additionalProperties"]?.boolValue ?? false
    let order = dict["x-order"]?.arrayValue?.compactMap { $0.stringValue } ?? Array(propertiesValue.keys).sorted()

    var objectDict: [String: JSONValue] = [
      "title": .string(dict["title"]?.stringValue ?? preferredTitle),
      "type": .string("object"),
      "properties": .object(normalizedProps),
      "required": .array(requiredNames.map(JSONValue.string)),
      "additionalProperties": .bool(additionalProperties),
      "x-order": .array(order.map(JSONValue.string))
    ]

    if let description = description ?? dict["description"]?.stringValue, !description.isEmpty {
      objectDict["description"] = .string(description)
    }

    return .object(objectDict)

  case "array":
    guard let itemsValue = dict["items"] else {
      throw SchemaConversionError.missingKey("items")
    }
    let normalizedItems = try normalizeSchema(
      name: "\(preferredTitle)Item",
      description: dict["items"]?.objectValue?["description"]?.stringValue,
      schema: itemsValue,
      preferredTitle: "\(preferredTitle)Item"
    )

    var arrayDict: [String: JSONValue] = [
      "type": .string("array"),
      "items": normalizedItems
    ]
    if let description = description ?? dict["description"]?.stringValue, !description.isEmpty {
      arrayDict["description"] = .string(description)
    }
    if let minItems = dict["minItems"]?.intValue {
      arrayDict["minItems"] = .number(Double(minItems))
    }
    if let maxItems = dict["maxItems"]?.intValue {
      arrayDict["maxItems"] = .number(Double(maxItems))
    }
    if let uniqueItems = dict["uniqueItems"]?.boolValue {
      arrayDict["uniqueItems"] = .bool(uniqueItems)
    }
    return .object(arrayDict)

  case "string", "integer", "number", "boolean":
    var primitive: [String: JSONValue] = [
      "type": .string(resolvedType)
    ]
    if let description = description ?? dict["description"]?.stringValue, !description.isEmpty {
      primitive["description"] = .string(description)
    }
    if let enumValues = dict["enum"]?.arrayValue {
      primitive["enum"] = .array(enumValues)
    }
    if let format = dict["format"]?.stringValue {
      primitive["format"] = .string(format)
    }
    return .object(primitive)

  default:
    throw SchemaConversionError.unsupportedSchema("Type \(resolvedType) for \(preferredTitle) is not supported")
  }
}

func makeGenerationSchema(
  name: String,
  description: String?,
  schema: JSONValue
) throws -> GenerationSchema {
  let normalized = try normalizeJSONSchema(name: name, description: description, schema: schema)
  let data = try JSONEncoder().encode(normalized)
  return try JSONDecoder().decode(GenerationSchema.self, from: data)
}

func stripJSONCodeFence(_ text: String) -> String {
  var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard trimmed.hasPrefix("```") else { return trimmed }

  trimmed.removeFirst(3)
  if let newlineIndex = trimmed.firstIndex(of: "\n") {
    trimmed = String(trimmed[trimmed.index(after: newlineIndex)...])
  } else {
    trimmed = ""
  }

  // Remove trailing code fence, which may be followed by <executable_end> or other markers
  if let fenceIndex = trimmed.range(of: "```", options: .backwards) {
    trimmed = String(trimmed[..<fenceIndex.lowerBound])
  }

  return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
}

func parseJSONValue(from text: String) -> JSONValue? {
  var stripped = stripJSONCodeFence(text)
  if stripped.hasPrefix("\"") && stripped.hasSuffix("\"") {
    if let data = stripped.data(using: .utf8), let decoded = try? JSONDecoder().decode(String.self, from: data) {
      stripped = decoded
    }
  }
  if let data = stripped.data(using: .utf8),
     let object = try? JSONSerialization.jsonObject(with: data),
     let json = JSONValue(any: object) {
    return json
  }

  let quoted = "\"\(stripped)\""
  if let data = quoted.data(using: .utf8),
     let decoded = try? JSONDecoder().decode(String.self, from: data) {
    if let decodedData = decoded.data(using: .utf8),
       let object = try? JSONSerialization.jsonObject(with: decodedData),
       let json = JSONValue(any: object) {
      return json
    }
  }

  return nil
}

struct ProcessedAssistantMessage {
  let content: String?
  let parsed: JSONValue?
  let toolCalls: [ChatCompletionPayload.Choice.ToolCall]?
  let finishReason: String
}

func processAssistantResponse(
  _ text: String,
  responseFormat: InputPayload.ResponseFormat?,
  hasTools: Bool,
  hasExecutedToolCalls: Bool
) -> ProcessedAssistantMessage {
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  var parsedJSON: JSONValue? = parseJSONValue(from: trimmed)
  if hasTools, parsedJSON == nil, trimmed.contains("\"tool_calls\""),
     let repaired = repairToolCallJSONIfNeeded(trimmed) {
    parsedJSON = parseJSONValue(from: repaired)
  }
  var toolCalls: [ChatCompletionPayload.Choice.ToolCall]? = nil
  var finishReason = hasExecutedToolCalls ? "stop" : "stop"
  var content: String? = trimmed

  if hasTools,
     let json = parsedJSON,
     case let .object(dict) = json,
     let toolCallsValue = dict["tool_calls"],
     case let .array(callArray) = toolCallsValue {
    var parsedCalls: [ChatCompletionPayload.Choice.ToolCall] = []
    var sawInvalid = false
    for element in callArray {
      if let call = makeToolCall(from: element) {
        parsedCalls.append(call)
      } else {
        sawInvalid = true
      }
    }
    if !parsedCalls.isEmpty {
      toolCalls = parsedCalls
      finishReason = "tool_calls"
      content = nil
      parsedJSON = nil
    } else if sawInvalid {
      parsedJSON = nil
    }
  }

  if hasTools, (toolCalls == nil || toolCalls?.isEmpty == true), let currentContent = content {
    let (extractedCalls, remainingContent) = extractToolCallsFromLooseContent(currentContent)
    if !extractedCalls.isEmpty {
      toolCalls = extractedCalls
      finishReason = "tool_calls"
      content = remainingContent
      parsedJSON = nil
    }
  }

  if responseFormat != nil && parsedJSON == nil {
    parsedJSON = parseJSONValue(from: trimmed)
  }

  return ProcessedAssistantMessage(content: content, parsed: parsedJSON, toolCalls: toolCalls, finishReason: finishReason)
}

func makeToolCall(from value: JSONValue) -> ChatCompletionPayload.Choice.ToolCall? {
  guard case let .object(dict) = value else { return nil }
  let id = makeOpenAIStyleToolCallID()

  let type: String
  if let typeValue = dict["type"], case let .string(typeString) = typeValue, !typeString.isEmpty {
    type = typeString
  } else {
    type = "function"
  }

  guard let functionValue = dict["function"], case let .object(functionObject) = functionValue,
        let nameValue = functionObject["name"], case let .string(name) = nameValue else {
    return nil
  }

  var argumentsJSON = "{}"
  if let argsValue = functionObject["arguments"] {
    if case let .string(rawString) = argsValue {
      argumentsJSON = rawString
    } else {
      let anyObject = argsValue.toAny()
      if JSONSerialization.isValidJSONObject(anyObject),
         let data = try? JSONSerialization.data(withJSONObject: anyObject, options: [.withoutEscapingSlashes]) {
        argumentsJSON = String(data: data, encoding: .utf8) ?? argumentsJSON
      } else if let data = try? JSONEncoder().encode(argsValue) {
        argumentsJSON = String(data: data, encoding: .utf8) ?? argumentsJSON
      }
    }
  }

  argumentsJSON = normalizeArgumentsString(argumentsJSON)

  let functionCall = ChatCompletionPayload.Choice.ToolCall.FunctionCall(name: name, arguments: argumentsJSON)
  return ChatCompletionPayload.Choice.ToolCall(id: id, type: type, function: functionCall)
}

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

private func makeToolPlanningSchema(
  toolSpecs: [InputPayload.ToolSpec],
  choice: InputPayload.ToolChoice?
) throws -> GenerationSchema {
  let allowedNames: [JSONValue] = {
    switch choice {
    case .function(let name)?:
      return [.string(name)]
    default:
      return toolSpecs.map { .string($0.function.name) }
    }
  }()

  let minItems: Double = {
    switch choice {
    case .function?:
      return 1
    default:
      return 0
    }
  }()

  var nameProperty: [String: JSONValue] = [
    "type": .string("string")
  ]
  if !allowedNames.isEmpty {
    nameProperty["enum"] = .array(allowedNames)
  }

  func argumentSchema(for tool: InputPayload.ToolSpec) -> JSONValue {
    if let params = tool.function.parameters {
      return params
    }
    return .object([
      "type": .string("object"),
      "additionalProperties": .bool(true)
    ])
  }

  let argumentOptions: [JSONValue] = toolSpecs.compactMap { tool in
    guard tool.type == "function" else { return nil }
    var schema = argumentSchema(for: tool)
    if case var .object(dict) = schema {
      if dict["type"] == nil {
        dict["type"] = .string("object")
      }
      dict["title"] = .string("Arguments for \(tool.function.name)")
      dict["description"] = .string(tool.function.description ?? "")
      schema = .object(dict)
    }
    return schema
  }

  let argumentsProperty: JSONValue = {
    if argumentOptions.count == 1 {
      return argumentOptions[0]
    } else if argumentOptions.count > 1 {
      return .object([
        "type": .string("object"),
        "oneOf": .array(argumentOptions)
      ])
    } else {
      return .object([
        "type": .string("object"),
        "additionalProperties": .bool(true)
      ])
    }
  }()

  let functionProperty: JSONValue = .object([
    "type": .string("object"),
    "required": .array([.string("name"), .string("arguments")]),
    "additionalProperties": .bool(false),
    "properties": .object([
      "name": .object(nameProperty),
      "arguments": argumentsProperty
    ])
  ])

  let callItem: JSONValue = .object([
    "type": .string("object"),
    "required": .array([.string("type"), .string("function")]),
    "additionalProperties": .bool(false),
    "properties": .object([
      "id": .object(["type": .string("string")]),
      "type": .object([
        "type": .string("string"),
        "enum": .array([.string("function")])
      ]),
      "function": functionProperty
    ])
  ])

  let root: JSONValue = .object([
    "title": .string("ToolPlan"),
    "type": .string("object"),
    "required": .array([.string("tool_calls")]),
    "additionalProperties": .bool(false),
    "properties": .object([
      "tool_calls": .object([
        "type": .string("array"),
        "minItems": .number(minItems),
        "items": callItem
      ])
    ])
  ])

  let normalized = try normalizeJSONSchema(name: "ToolPlan", description: "Structured tool-call plan", schema: root)
  let data = try JSONEncoder().encode(normalized)
  return try JSONDecoder().decode(GenerationSchema.self, from: data)
}

func buildResponseFormatInstruction(_ format: InputPayload.ResponseFormat) -> String? {
  switch format.type {
  case .jsonSchema:
    guard let payload = format.jsonSchema else { return nil }
    guard let schemaText = prettyJSONString(from: payload.schema) else { return nil }
    var parts: [String] = []
    parts.append("You must respond with **only** JSON that matches the \(payload.name) schema exactly. Do not add prose, apologies, or follow-up questions.")
    parts.append("If the user leaves out details, invent reasonable values so that all required fields are filled. Never reply with clarifying questions.")
    if let requiredKeys = extractTopLevelKeys(from: payload.schema), !requiredKeys.isEmpty {
      let keyList = requiredKeys.joined(separator: ", ")
      parts.append("Required property names: \(keyList). Use these exact spellings and do not introduce additional top-level keys.")
    }
    if let description = payload.description, !description.isEmpty {
      parts.append("Schema description: \(description)")
    }
    parts.append("Schema (JSON Schema v7 style):")
    parts.append(schemaText)
    if payload.strict == true {
      parts.append("The schema is strict: no additional fields or alternate formats are allowed.")
    }
    return parts.joined(separator: "\n\n")
  }
}

private func extractTopLevelKeys(from schema: JSONValue) -> [String]? {
  guard case let .object(root) = schema else { return nil }
  if let properties = root["properties"], case let .object(dict) = properties {
    return dict.keys.sorted()
  }
  if let required = root["required"], case let .array(items) = required {
    return items.compactMap { item in
      if case let .string(value) = item { return value }
      return nil
    }
  }
  return nil
}

private struct AnyEncodable: Encodable {
  private let encodeClosure: (Encoder) throws -> Void

  init(_ wrapped: any Encodable) {
    let value = wrapped
    self.encodeClosure = { encoder in try value.encode(to: encoder) }
  }

  func encode(to encoder: Encoder) throws {
    try encodeClosure(encoder)
  }
}

private func renderStructuredContent(from content: Any) -> (String, JSONValue?) {
  if let encodable = content as? any Encodable {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    if let data = try? encoder.encode(AnyEncodable(encodable)),
       let text = String(data: data, encoding: .utf8),
       let jsonObject = try? JSONSerialization.jsonObject(with: data),
       let jsonValue = JSONValue(any: jsonObject) {
      return (text, jsonValue)
    }
  }

  if let string = content as? String {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    return (trimmed, parseJSONValue(from: trimmed))
  }

  if let dict = content as? [String: Any], JSONSerialization.isValidJSONObject(dict),
     let data = try? JSONSerialization.data(withJSONObject: dict, options: [.withoutEscapingSlashes, .prettyPrinted]),
     let text = String(data: data, encoding: .utf8) {
    return (text, JSONValue(any: dict))
  }

  if let array = content as? [Any], JSONSerialization.isValidJSONObject(array),
     let data = try? JSONSerialization.data(withJSONObject: array, options: [.withoutEscapingSlashes, .prettyPrinted]),
     let text = String(data: data, encoding: .utf8) {
    return (text, JSONValue(any: array))
  }

  let stringified = String(describing: content)
  return (stringified, parseJSONValue(from: stringified))
}

private func decodeEscapedStreamingContent(_ raw: String) -> String {
  let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  guard trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") else {
    return raw
  }
  if let data = trimmed.data(using: .utf8), let decoded = try? JSONDecoder().decode(String.self, from: data) {
    return decoded
  }
  return raw
}

private func makeOpenAIStyleToolCallID() -> String {
  let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
  var characters: [Character] = []
  characters.reserveCapacity(24)
  for _ in 0..<24 {
    if let random = alphabet.randomElement() {
      characters.append(random)
    } else {
      characters.append("0")
    }
  }
  return "call_" + String(characters)
}

func buildToolsInstruction(
  toolSpecs: [InputPayload.ToolSpec],
  choice: InputPayload.ToolChoice?
) -> String {
  if case .none? = choice {
    return "Tool calling is disabled for this request. Respond directly to the user in natural language without mentioning tools or function calls."
  }

  var lines: [String] = []
  lines.append("Decide whether a function call is required. If so, select the appropriate function and provide arguments that allow it to run successfully.")
  lines.append("Represent each decision as an entry in the tool_calls list (id, type \"function\", function name and arguments). Leave tool_calls empty when no function is needed.")
  lines.append("If the user explicitly requests a tool or function by name, or asks you to call a tool, you must include that function in tool_calls with appropriate arguments before returning.")
  lines.append("Arguments must include every required field from the schema. Do not emit empty objects or omit mandatory keys.")
  lines.append("Example tool_calls entry: [ { \"id\": \"call_read\", \"type\": \"function\", \"function\": { \"name\": \"read_file\", \"arguments\": { \"path\": \"calculator.py\" } } } ]")

  switch choice {
  case .function(let name)?:
    lines.append("You must call the function named \(name) before returning a final answer.")
  default:
    break
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

func buildToolCatalogInstruction(toolSpecs: [InputPayload.ToolSpec]) -> String? {
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

private func normalizeArgumentsString(_ raw: String) -> String {
  guard let data = raw.data(using: .utf8),
        let object = try? JSONSerialization.jsonObject(with: data),
        JSONSerialization.isValidJSONObject(object),
        let normalizedData = try? JSONSerialization.data(withJSONObject: object, options: []),
        let text = String(data: normalizedData, encoding: .utf8) else {
    return raw
  }
  return text
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

private func repairToolCallJSONIfNeeded(_ text: String) -> String? {
  guard text.contains("\"tool_calls\"") else { return nil }

  let scalars = Array(text.unicodeScalars)
  var result = String.UnicodeScalarView()
  result.reserveCapacity(scalars.count)

  var index = scalars.startIndex
  var inString = false
  var escapeNext = false

  while index < scalars.endIndex {
    let scalar = scalars[index]

    if escapeNext {
      result.append(scalar)
      escapeNext = false
      index = scalars.index(after: index)
      continue
    }

    if scalar == "\"" {
      inString.toggle()
      result.append(scalar)
      index = scalars.index(after: index)
      continue
    }

    if scalar == "\\" {
      if inString {
        let nextIndex = scalars.index(after: index)
        if nextIndex < scalars.endIndex, scalars[nextIndex] == "\"" {
          var lookahead = scalars.index(after: nextIndex)
          while lookahead < scalars.endIndex {
            let la = scalars[lookahead]
            if CharacterSet.whitespacesAndNewlines.contains(la) {
              lookahead = scalars.index(after: lookahead)
              continue
            }
            if la == "," || la == "}" || la == "]" {
              index = nextIndex
              // do not append backslash; let upcoming quote terminate the string
              break
            }
            break
          }
          if index == nextIndex {
            continue
          }
        }
        result.append(scalar)
        escapeNext = true
        index = scalars.index(after: index)
        continue
      } else {
        result.append(scalar)
        index = scalars.index(after: index)
        continue
      }
    }

    result.append(scalar)
    index = scalars.index(after: index)
  }

  let repaired = String(result)
  return repaired == text ? nil : repaired
}

private func extractToolCallsFromLooseContent(_ text: String) -> ([ChatCompletionPayload.Choice.ToolCall], String?) {
  if let repaired = repairToolCallJSONIfNeeded(text),
     let json = parseJSONValue(from: repaired),
     case let .object(dict) = json,
     let array = dict["tool_calls"]?.arrayValue {
    let calls = array.compactMap(makeToolCall(from:))
    if !calls.isEmpty {
      return (calls, nil)
    }
  }
  return ([], text)
}

private func decodeToolPlan(from content: Any) throws -> ToolPlan {
  var lastError: Error? = nil

  if let generated = content as? GeneratedContent {
    let (text, json) = renderStructuredContent(from: generated)
    if let json {
      let data = try JSONEncoder().encode(json)
      if let plan = try? JSONDecoder().decode(ToolPlan.self, from: data) {
        return plan
      }
    }
    if let data = text.data(using: .utf8), let plan = try? JSONDecoder().decode(ToolPlan.self, from: data) {
      return plan
    }
  }

  // 1) If the framework gave us a typed/encodable value (e.g. GeneratedContent),
  //    encode it to JSON bytes and decode ToolPlan directly.
  if let enc = content as? any Encodable {
    do {
      let data = try JSONEncoder().encode(AnyEncodable(enc))
      return try JSONDecoder().decode(ToolPlan.self, from: data)
    } catch {
      lastError = error
    }
  }

  // 2) Handle cases you already had
  if let plan = content as? ToolPlan { return plan }

  if let jsonValue = content as? JSONValue {
    let data = try JSONEncoder().encode(jsonValue)
    return try JSONDecoder().decode(ToolPlan.self, from: data)
  }

  if let dict = content as? [String: Any], JSONSerialization.isValidJSONObject(dict) {
    let data = try JSONSerialization.data(withJSONObject: dict, options: [])
    return try JSONDecoder().decode(ToolPlan.self, from: data)
  }

  if let string = content as? String, let data = string.data(using: .utf8) {
    return try JSONDecoder().decode(ToolPlan.self, from: data)
  }

  // 3) Last-ditch: some types expose valid JSON via .description
  if let desc = (content as? CustomStringConvertible)?.description,
     let data = desc.data(using: .utf8) {
    return try JSONDecoder().decode(ToolPlan.self, from: data)
  }

  if let lastError {
    throw ChatEngineError.invalidSchema("Unable to decode tool planning response: \(lastError)")
  }
  throw ChatEngineError.invalidSchema("Unable to decode tool planning response")
}


func makeTranscript(from messages: [Message], extraInstructions: [String]) -> Transcript {
  func textSegment(_ text: String) -> Transcript.Segment {
    Transcript.Segment.text(Transcript.TextSegment(content: text))
  }

  var entries: [Transcript.Entry] = []
  var instructionSegments: [Transcript.Segment] = []

  // Insert our extra instructions first so they take precedence over any
  // user-provided system messages that might contradict them.
  for instruction in extraInstructions where !instruction.isEmpty {
    instructionSegments.append(textSegment(instruction))
  }
  for message in messages {
    switch message.role {
    case .system:
      if let content = message.content, !content.isEmpty {
        instructionSegments.append(textSegment(content))
      }
    case .user:
      guard let content = message.content else {
        fputs("[syslm-core] warning: user message missing content, skipping\n", stderr)
        continue
      }
      let prompt = Transcript.Prompt(segments: [textSegment(content)])
      entries.append(.prompt(prompt))
    case .assistant:
      guard let content = message.content, !content.isEmpty else { continue }
      let response = Transcript.Response(assetIDs: [], segments: [textSegment(content)])
      entries.append(.response(response))
    case .tool:
      guard let content = message.content else {
        fputs("[syslm-core] warning: tool message missing content, skipping\n", stderr)
        continue
      }
      let prompt = Transcript.Prompt(segments: [textSegment(content)])
      entries.append(.prompt(prompt))
    }
  }

  if !instructionSegments.isEmpty {
    let instructions = Transcript.Instructions(segments: instructionSegments, toolDefinitions: [])
    entries.insert(.instructions(instructions), at: 0)
  }

  return Transcript(entries: entries)
}

private func prepareSession(for payload: InputPayload) throws -> PreparedSession {
  var warnings: [String] = []

  guard !payload.messages.isEmpty else {
    throw ChatEngineError.emptyMessages
  }
  guard let lastMessage = payload.messages.last else {
    throw ChatEngineError.lastMessageNotUser
  }
  switch lastMessage.role {
  case .user, .tool:
    break
  default:
    throw ChatEngineError.lastMessageNotUser
  }
  guard let lastContent = lastMessage.content else {
    throw ChatEngineError.invalidMessage("final user message is missing content")
  }
  let systemModel = SystemLanguageModel(guardrails: .permissiveContentTransformations)
  guard systemModel.isAvailable else {
    throw ChatEngineError.modelUnavailable(String(describing: systemModel.availability))
  }

  var declaredToolSpecs: [InputPayload.ToolSpec] = []
  if let specs = payload.tools {
    for spec in specs {
      if spec.type != "function" {
        warnings.append("Tool type \(spec.type) is unsupported; only 'function' tools are emitted")
        continue
      }
      declaredToolSpecs.append(spec)
    }
  }

  var toolChoiceInstruction: String? = nil

  switch payload.toolChoice {
  case .none?:
    declaredToolSpecs.removeAll()
  toolChoiceInstruction = """
Tool calling is disabled. Answer the user's request directly in natural language. It's fine to explain why tool choice is none, but do not attempt to invoke any tools.
"""
  case .function(let requiredName)?:
    if declaredToolSpecs.contains(where: { $0.function.name == requiredName }) {
      declaredToolSpecs = declaredToolSpecs.filter { $0.function.name == requiredName }
    } else {
      throw ChatEngineError.invalidToolChoice(requiredName)
    }
  case .auto?, nil:
    break
  }

  var effectiveToolChoice: InputPayload.ToolChoice? = payload.toolChoice
  if effectiveToolChoice == nil {
    let lowercasedPrompt = lastContent.lowercased()
    if let match = declaredToolSpecs.first(where: { lowercasedPrompt.contains($0.function.name.lowercased()) }) {
      effectiveToolChoice = .function(name: match.function.name)
    } else if declaredToolSpecs.count == 1 {
      let keywords = ["call", "invoke", "use", "run"]
      if keywords.contains(where: { lowercasedPrompt.contains($0) }) {
        effectiveToolChoice = .function(name: declaredToolSpecs[0].function.name)
      }
    }
  }

  if case .function(let requiredName)? = effectiveToolChoice,
     !declaredToolSpecs.isEmpty,
     !declaredToolSpecs.contains(where: { $0.function.name == requiredName }) {
    if payload.toolChoice == nil {
      // Heuristic produced a tool name no longer present; keep declared specs unchanged.
      effectiveToolChoice = nil
    } else {
      throw ChatEngineError.invalidToolChoice(requiredName)
    }
  }

  if case .function(let requiredName)? = effectiveToolChoice {
    if let match = declaredToolSpecs.first(where: { $0.function.name == requiredName }) {
      declaredToolSpecs = [match]
    }
  }

  var generationSchema: GenerationSchema? = nil
  if let format = payload.responseFormat, format.type == .jsonSchema, let json = format.jsonSchema {
    do {
      generationSchema = try makeGenerationSchema(
        name: json.name,
        description: json.description,
        schema: json.schema
      )
    } catch {
      throw ChatEngineError.invalidSchema(String(describing: error))
    }
  }

  var baseInstructions: [String] = []
  if let format = payload.responseFormat, generationSchema == nil, let instruction = buildResponseFormatInstruction(format) {
    baseInstructions.append(instruction)
  }
  if let catalog = buildToolCatalogInstruction(toolSpecs: declaredToolSpecs) {
    baseInstructions.append(catalog)
  }

  if let toolInstruction = toolChoiceInstruction {
    baseInstructions.append(toolInstruction)
  }

  let historyMessages = Array(payload.messages.dropLast())

  var options = GenerationOptions()
  if let temperature = payload.temperature {
    options.temperature = temperature
  } else if generationSchema != nil {
    options.temperature = 0
  }
  if let topK = payload.topK {
    options.sampling = .random(top: topK, seed: nil)
  } else if generationSchema != nil {
    options.sampling = .greedy
  }
  if let maxTokens = payload.maxOutputTokens {
    options.maximumResponseTokens = maxTokens
  }
  if generationSchema != nil && options.maximumResponseTokens == nil {
    options.maximumResponseTokens = 512
  }

  let promptContent = lastContent
  return PreparedSession(
    lastMessage: lastMessage,
    declaredToolSpecs: declaredToolSpecs,
    generationSchema: generationSchema,
    options: options,
    warnings: warnings,
    promptContent: promptContent,
    toolChoice: payload.toolChoice,
    effectiveToolChoice: effectiveToolChoice,
    systemModel: systemModel,
    baseInstructions: baseInstructions,
    historyMessages: historyMessages
  )
}

func extractToolCalls(from entries: ArraySlice<Transcript.Entry>) -> [ChatCompletionPayload.Choice.ToolCall] {
  var result: [ChatCompletionPayload.Choice.ToolCall] = []
  for entry in entries {
    if case .toolCalls(let calls) = entry {
      for call in calls {
        let argumentsString = String(describing: call.arguments)
        let function = ChatCompletionPayload.Choice.ToolCall.FunctionCall(name: call.toolName, arguments: argumentsString)
        result.append(.init(id: makeOpenAIStyleToolCallID(), type: "function", function: function))
      }
    }
  }
  return result
}

public struct ChatCompletionPayload: Encodable {
  public struct Choice: Encodable {
    public struct ChoiceMessage: Encodable {
      public let role: String
      public let content: String?
      public let parsed: JSONValue?
      public let toolCalls: [ToolCall]?
    }

    public struct ToolCall: Encodable {
      public struct FunctionCall: Encodable {
        public let name: String
        public let arguments: String
      }

      public let id: String
      public let type: String
      public let function: FunctionCall
    }

    public let index: Int
    public let message: ChoiceMessage
    public let finishReason: String?
  }

  public let id: String
  public let object: String
  public let created: Int
  public let model: String
  public let choices: [Choice]
}

public struct ChatEngine {
  public struct Result: @unchecked Sendable {
    public let response: ChatCompletionPayload
    public let warnings: [String]
    public let choice: ChatCompletionPayload.Choice
  }

  public struct StreamResponse: @unchecked Sendable {
    public let id: String
    public let model: String
    public let created: Int
    public let warnings: [String]
    public let events: AsyncThrowingStream<StreamEvent, Error>
  }

  public enum StreamEvent: Sendable {
    case role(String)
    case content(String)
    case finish(String?)
  }

  public static func process(payload: InputPayload) async throws -> Result {
    let prepared = try prepareSession(for: payload)
    var warnings = prepared.warnings
    let options = prepared.options

    let historyMessages = prepared.historyMessages
    let answerTranscript = makeTranscript(from: historyMessages, extraInstructions: prepared.baseInstructions)
    let answerSession = LanguageModelSession(model: prepared.systemModel, tools: [], transcript: answerTranscript)

    let response: ChatCompletionPayload
    let choice: ChatCompletionPayload.Choice

    if let schema = prepared.generationSchema {
      let generated = try await answerSession.respond(
        to: prepared.promptContent,
        schema: schema,
        includeSchemaInPrompt: true,
        options: options
      )
      let toolCalls = extractToolCalls(from: generated.transcriptEntries)
      let (jsonText, parsed) = renderStructuredContent(from: generated.content)

      let generatedChoice = ChatCompletionPayload.Choice(
        index: 0,
        message: .init(
          role: "assistant",
          content: jsonText,
          parsed: parsed,
          toolCalls: toolCalls.isEmpty ? nil : toolCalls
        ),
        finishReason: "stop"
      )

      response = ChatCompletionPayload(
        id: "chatcmpl-" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
        object: "chat.completion",
        created: Int(Date().timeIntervalSince1970),
        model: "ondevice",
        choices: [generatedChoice]
      )

      choice = generatedChoice
    } else {
      var hasTools = !prepared.declaredToolSpecs.isEmpty
      fputs("[syslm-core] tool availability: hasTools=\(hasTools) count=\(prepared.declaredToolSpecs.count)\n", stderr)
      fputs("[syslm-core] effectiveToolChoice: \(String(describing: prepared.effectiveToolChoice))\n", stderr)

      if hasTools {
        do {
          var planningInstructions = prepared.baseInstructions
          planningInstructions.append(buildToolsInstruction(toolSpecs: prepared.declaredToolSpecs, choice: prepared.effectiveToolChoice))
          fputs("[syslm-core] planning instructions count: \(planningInstructions.count)\n", stderr)
          let planningTranscript = makeTranscript(
            from: historyMessages,
            extraInstructions: planningInstructions
          )
          let planningSession = LanguageModelSession(model: prepared.systemModel, tools: [], transcript: planningTranscript)
          let planningSchema = try makeToolPlanningSchema(toolSpecs: prepared.declaredToolSpecs, choice: prepared.effectiveToolChoice)
          var planningOptions = options
          planningOptions.sampling = .greedy
          planningOptions.temperature = 0
          planningOptions.maximumResponseTokens = max(planningOptions.maximumResponseTokens ?? 0, 256)

          let planningResponse = try await planningSession.respond(
            to: prepared.promptContent,
            schema: planningSchema,
            includeSchemaInPrompt: true,
            options: planningOptions
          )

          let rawPlanContent = planningResponse.content
          fputs("[syslm-core] raw tool plan content type=\(String(describing: type(of: rawPlanContent))) value=\(String(describing: rawPlanContent))\n", stderr)
          let plan = try decodeToolPlan(from: rawPlanContent)
          if !plan.tool_calls.isEmpty {
            let toolCalls = plan.tool_calls.map { call -> ChatCompletionPayload.Choice.ToolCall in
              let id = (call.id?.isEmpty == false) ? call.id! : makeOpenAIStyleToolCallID()
              let type = (call.type?.isEmpty == false) ? call.type! : "function"
              fputs("[syslm-core] planned call name=\(call.function.name) arguments=\(call.function.arguments)\n", stderr)
              let argumentsText = canonicalJSONString(from: call.function.arguments)
              let functionCall = ChatCompletionPayload.Choice.ToolCall.FunctionCall(name: call.function.name, arguments: argumentsText)
              return .init(id: id, type: type, function: functionCall)
            }

            let generatedChoice = ChatCompletionPayload.Choice(
              index: 0,
              message: .init(role: "assistant", content: nil, parsed: nil, toolCalls: toolCalls),
              finishReason: "tool_calls"
            )

            let toolResponse = ChatCompletionPayload(
              id: "chatcmpl-" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
              object: "chat.completion",
              created: Int(Date().timeIntervalSince1970),
              model: "ondevice",
              choices: [generatedChoice]
            )

            return Result(response: toolResponse, warnings: warnings, choice: generatedChoice)
          }
          fputs("[syslm-core] tool planning returned no calls\n", stderr)
          hasTools = false
        } catch {
          warnings.append("tool planning failed: \(error)")
          fputs("[syslm-core] tool planning failed: \(error)\n", stderr)
        }
      }

      let generated = try await answerSession.respond(to: prepared.promptContent, options: options)
      let transcriptToolCalls = extractToolCalls(from: generated.transcriptEntries)

      let processed = processAssistantResponse(
        generated.content,
        responseFormat: payload.responseFormat,
        hasTools: hasTools,
        hasExecutedToolCalls: !transcriptToolCalls.isEmpty
      )

      var combinedToolCalls = transcriptToolCalls
      if combinedToolCalls.isEmpty, let extra = processed.toolCalls {
        combinedToolCalls = extra
      } else if let extra = processed.toolCalls, !extra.isEmpty {
        combinedToolCalls.append(contentsOf: extra)
      }

      var responseContent = processed.content
      var responseParsed = processed.parsed
      var finishReason = (!combinedToolCalls.isEmpty && responseContent == nil)
        ? "tool_calls"
        : processed.finishReason

      if combinedToolCalls.isEmpty, hasTools, let contentText = responseContent {
        let (extracted, residual) = extractToolCallsFromLooseContent(contentText)
        if !extracted.isEmpty {
          combinedToolCalls = extracted
          responseContent = residual
          responseParsed = nil
          finishReason = "tool_calls"
        }
      }

      if !hasTools, let text = responseContent, text.contains("\"tool_calls\"") {
        let (extracted, residual) = extractToolCallsFromLooseContent(text)
        if !extracted.isEmpty {
          responseContent = residual
        }
      }

      let generatedChoice = ChatCompletionPayload.Choice(
        index: 0,
        message: .init(
          role: "assistant",
          content: responseContent,
          parsed: responseParsed,
          toolCalls: combinedToolCalls.isEmpty ? nil : combinedToolCalls
        ),
        finishReason: finishReason
      )

      response = ChatCompletionPayload(
        id: "chatcmpl-" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
        object: "chat.completion",
        created: Int(Date().timeIntervalSince1970),
        model: "ondevice",
        choices: [generatedChoice]
      )

      choice = generatedChoice
    }

    return Result(response: response, warnings: warnings, choice: choice)
  }

  public static func stream(payload: InputPayload) throws -> StreamResponse {
    let prepared = try prepareSession(for: payload)
    if prepared.generationSchema != nil {
      throw ChatEngineError.streamingUnsupported("response_format json_schema")
    }

    let created = Int(Date().timeIntervalSince1970)
    let id = "chatcmpl-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let model = "ondevice"
    let transcript = makeTranscript(from: prepared.historyMessages, extraInstructions: prepared.baseInstructions)
    let session = LanguageModelSession(model: prepared.systemModel, tools: [], transcript: transcript)
    let options = prepared.options

    let events = AsyncThrowingStream<StreamEvent, Error>(bufferingPolicy: .unbounded) { continuation in
      let stream = session.streamResponse(to: prepared.promptContent, options: options)
      let task = Task {
        continuation.yield(StreamEvent.role("assistant"))
        var previous = ""
        let finish = "stop"
        do {
          for try await snapshot in stream {
            let raw = String(describing: snapshot.rawContent)
            let content = decodeEscapedStreamingContent(raw)
            guard content.count >= previous.count else { continue }
            let delta = String(content.dropFirst(previous.count))
            previous = content
            if !delta.isEmpty {
              continuation.yield(StreamEvent.content(delta))
            }
          }
          continuation.yield(StreamEvent.finish(finish))
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }

    return StreamResponse(id: id, model: model, created: created, warnings: prepared.warnings, events: events)
  }
}
