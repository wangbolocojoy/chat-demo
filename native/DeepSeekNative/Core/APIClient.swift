import Foundation

/// 接口错误：带上 HTTP 状态码和可展示的文案
struct APIError: LocalizedError {
  let message: String
  let status: Int?
  var errorDescription: String? { message }
}

/// DeepSeek 接口的 Swift 客户端。
/// 聊天走 Anthropic 兼容的 `/anthropic/v1/messages`（SSE 流式），
/// 语音走 `/v1/tools/asr`（整段识别）和 `/v1/tools/tts`（PCM 流式合成）。
struct APIClient {
  let origin: URL
  let apiKey: String

  private let session: URLSession = {
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 60 * 30
    return URLSession(configuration: configuration)
  }()

  // MARK: - 基础请求

  private func makeRequest(
    path: String,
    method: String = "POST",
    contentType: String = "application/json",
    accept: String = "application/json",
    body: Data? = nil
  ) -> URLRequest {
    var request = URLRequest(url: origin.appending(path: path))
    request.httpMethod = method
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue(contentType, forHTTPHeaderField: "Content-Type")
    request.setValue(accept, forHTTPHeaderField: "Accept")
    request.httpBody = body
    return request
  }

  private func validate(_ response: URLResponse) async throws -> HTTPURLResponse {
    guard let http = response as? HTTPURLResponse else {
      DLog.log("http invalid response")
      throw APIError(message: "响应格式异常", status: nil)
    }
    guard (200..<300).contains(http.statusCode) else {
      DLog.log("http \(http.statusCode) for \(http.url?.path ?? "?")")
      throw APIError(message: Self.errorMessage(status: http.statusCode), status: http.statusCode)
    }
    return http
  }

  /// 用 GET /models 校验 API Key（不产生费用）
  func verifyAPIKey() async throws {
    let request = makeRequest(path: "models", method: "GET")
    let (data, response) = try await session.data(for: request)
    _ = try await validate(response)
    _ = data
  }

  private static func errorMessage(status: Int) -> String {
    switch status {
    case 401: return "API Key 无效"
    case 402: return "账户余额不足"
    case 413: return "内容过大"
    case 429: return "请求过于频繁，请稍后再试"
    case 500...: return "服务繁忙，请稍后再试"
    default: return "请求失败（HTTP \(status)）"
    }
  }

  // MARK: - 聊天

  private struct ThinkingParameter: Encodable {
    let type: String
  }

  struct ToolSpec: Encodable {
    let type: String
    let name: String
  }

  private struct SafetyCheck: Encodable {
    let level: String
  }

  private struct MessageRequestBody: Encodable {
    let model: String
    let system: String
    let messages: [WireMessage]
    let thinking: ThinkingParameter
    let stream: Bool
    let tools: [ToolSpec]?
    let safety_check: SafetyCheck?
  }

  /// 流式生成回答；每个内容增量回调一次，收到 message_stop 后结束
  func streamReply(
    system: String,
    messages: [WireMessage],
    model: String = "deepseek-flash",
    thinking: Bool,
    tools: [ToolSpec]? = nil
  ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let body = MessageRequestBody(
            model: model,
            system: system,
            messages: messages,
            thinking: ThinkingParameter(type: thinking ? "enabled" : "disabled"),
            stream: true,
            tools: tools,
            safety_check: SafetyCheck(level: "high")
          )
          let data = try JSONEncoder().encode(body)
          let request = makeRequest(
            path: "anthropic/v1/messages",
            accept: "text/event-stream",
            body: data
          )
          let (bytes, response) = try await session.bytes(for: request)
          _ = try await validate(response)

          var decoder = SSEDecoder()
          var stopReason: String?
          var finished = false

          func handle(_ event: SSEDecoder.Event) throws {
            if event.event == "error" {
              throw APIError(message: event.data, status: nil)
            }
            guard
              let payload = try? JSONSerialization.jsonObject(with: Data(event.data.utf8))
                as? [String: Any]
            else {
              return
            }
            if let error = payload["error"] as? [String: Any],
              let message = error["message"] as? String
            {
              throw APIError(message: message, status: nil)
            }
            switch payload["type"] as? String {
            case "content_block_start":
              guard
                let index = payload["index"] as? Int,
                let block = payload["content_block"]
              else { return }
              continuation.yield(.blockStart(index: index, block: JSONValue.from(block)))
            case "content_block_stop":
              guard let index = payload["index"] as? Int else { return }
              continuation.yield(.blockStop(index: index))
            case "content_block_delta":
              guard
                let index = payload["index"] as? Int,
                let delta = payload["delta"] as? [String: Any],
                let kind = delta["type"] as? String
              else { return }
              if kind == "text_delta", let text = delta["text"] as? String {
                continuation.yield(.text(index: index, text))
              } else if kind == "thinking_delta", let text = delta["thinking"] as? String {
                continuation.yield(.thinking(index: index, text))
              } else if kind == "signature_delta", let signature = delta["signature"] as? String {
                continuation.yield(.signature(index: index, signature: signature))
              }
            case "message_delta":
              guard let delta = payload["delta"] as? [String: Any] else { return }
              if let reason = delta["stop_reason"] as? String {
                stopReason = reason
              }
              if let title = delta["title"] as? String, !title.isEmpty {
                continuation.yield(.title(title))
              }
            case "message_stop":
              finished = true
              continuation.yield(.finished(stopReason: stopReason))
              continuation.finish()
            default:
              break
            }
          }

          // 自己按 0x0A 切行：AsyncBytes.lines 不产出空行，而 SSE 靠空行派发事件
          var lineBuffer = Data()
          for try await byte in bytes {
            if byte == 0x0A {
              let line = String(decoding: lineBuffer, as: UTF8.self)
              lineBuffer.removeAll(keepingCapacity: true)
              if let event = decoder.consume(line: line) {
                try handle(event)
              }
              if finished { return }
            } else {
              lineBuffer.append(byte)
            }
          }
          if !lineBuffer.isEmpty, let event = decoder.consume(line: String(decoding: lineBuffer, as: UTF8.self)) {
            try handle(event)
          }
          if let event = decoder.finish() {
            try handle(event)
          }
          if !finished {
            continuation.finish(throwing: APIError(message: "连接中断", status: nil))
          }
        } catch is CancellationError {
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  // MARK: - 文件上传

  /// 上传图片到 Files API，返回 file_id（消息里用 image 块引用）
  func uploadImage(data: Data, mimeType: String, filename: String) async throws -> String {
    let boundary = "----DeepSeekNative\(UUID().uuidString)"
    var body = Data()
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append(
      "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!
    )
    body.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
    body.append(data)
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

    var request = makeRequest(
      path: "anthropic/v1/files",
      contentType: "multipart/form-data; boundary=\(boundary)",
      body: body
    )
    request.setValue("files-api-2025-04-14", forHTTPHeaderField: "anthropic-beta")
    let (responseData, response) = try await session.data(for: request)
    _ = try await validate(response)
    guard
      let payload = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
      let fileId = payload["id"] as? String
    else {
      throw APIError(message: "上传结果格式异常", status: nil)
    }
    return fileId
  }

  // MARK: - 语音识别

  /// 上传整段 WAV，返回转写文本
  func transcribe(wav: Data) async throws -> String {
    let boundary = "----DeepSeekNative\(UUID().uuidString)"
    var body = Data()
    body.append("--\(boundary)\r\n".data(using: .utf8)!)
    body.append(
      "Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\n"
        .data(using: .utf8)!
    )
    body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
    body.append(wav)
    body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

    let request = makeRequest(
      path: "v1/tools/asr",
      contentType: "multipart/form-data; boundary=\(boundary)",
      body: body
    )
    let (data, response) = try await session.data(for: request)
    _ = try await validate(response)
    guard
      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let text = payload["text"] as? String
    else {
      throw APIError(message: "识别结果格式异常", status: nil)
    }
    return text
  }

  // MARK: - 语音合成

  /// 流式合成 PCM（24 kHz、16-bit、单声道），按 100 ms 一包回调
  func synthesize(text: String, voice: String) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let payload: [String: Any] = [
            "text": text,
            "voice_id": voice,
            "format": "pcm",
            "filter_markdown": true,
          ]
          let body = try JSONSerialization.data(withJSONObject: payload)
          let request = makeRequest(
            path: "v1/tools/tts",
            contentType: "application/json",
            accept: "application/octet-stream",
            body: body
          )
          let (bytes, response) = try await session.bytes(for: request)
          _ = try await validate(response)
          var buffer = Data()
          for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 4800 {
              continuation.yield(buffer)
              buffer.removeAll(keepingCapacity: true)
            }
          }
          if !buffer.isEmpty {
            continuation.yield(buffer)
          }
          continuation.finish()
        } catch is CancellationError {
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
