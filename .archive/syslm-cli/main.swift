import Foundation
import FoundationModels
import syslm_core

struct AvailabilityResponse: Encodable {
  let ready: Bool
  let reason: String?
}

enum CLI {
  static func readAllSTDIN() -> String {
    var data = Data()
    while true {
      do {
        guard let chunk = try FileHandle.standardInput.read(upToCount: 1 << 14), !chunk.isEmpty else {
          break
        }
        data.append(chunk)
      } catch {
        break
      }
    }
    return String(data: data, encoding: .utf8) ?? ""
  }

  static func printJSON<T: Encodable>(_ value: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.withoutEscapingSlashes]
    enc.keyEncodingStrategy = .convertToSnakeCase
    let data = try! enc.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
  }

  static func fail(_ msg: String, code: Int32 = 1) -> Never {
    fputs("ERROR: \(msg)\n", stderr)
    exit(code)
  }

  static func warn(_ msg: String) {
    fputs("WARN: \(msg)\n", stderr)
  }
}

@main
struct App {
  static func main() async {
    let args = CommandLine.arguments.dropFirst()

    if args.contains("--availability") {
      let avail = SystemLanguageModel.default.availability
      switch avail {
      case .available:
        CLI.printJSON(AvailabilityResponse(ready: true, reason: nil))
      case .unavailable(let reason):
        CLI.printJSON(AvailabilityResponse(ready: false, reason: String(describing: reason)))
      @unknown default:
        CLI.printJSON(AvailabilityResponse(ready: false, reason: "unknown"))
      }
      return
    }

    let stdin = CLI.readAllSTDIN().trimmingCharacters(in: .whitespacesAndNewlines)
    guard !stdin.isEmpty else {
      CLI.fail("stdin is empty; expected JSON with { messages: [...] }")
    }

    let payload: InputPayload
    do {
      payload = try JSONDecoder().decode(InputPayload.self, from: Data(stdin.utf8))
    } catch {
      CLI.fail("failed to parse input JSON: \(error)")
    }

    guard SystemLanguageModel.default.isAvailable else {
      let reason = String(describing: SystemLanguageModel.default.availability)
      CLI.fail("SystemLanguageModel is unavailable: \(reason)", code: 2)
    }

    do {
      let result = try await ChatEngine.process(payload: payload)
      for warning in result.warnings {
        CLI.warn(warning)
      }
      CLI.printJSON(result.response)
    } catch let error as ChatEngineError {
      CLI.fail(error.description)
    } catch {
      CLI.fail("generation failed: \(error)")
    }
  }
}
