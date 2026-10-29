import Foundation

enum AttachmentKind: String, Hashable, Sendable {
    case image
    case file
}

enum AttachmentState: Equatable, Hashable, Sendable {
    case ready
    case uploading(Double)
    case uploaded(receiptId: String)
    case failed(String)
}

/// 输入框里待发送的附件。图片直接内联 base64；其他文件先传 `/v1/upload` 拿 receiptId。
struct ChatAttachment: Identifiable, Hashable, Sendable {
    var id: String
    var kind: AttachmentKind
    var fileName: String
    var mediaType: String?
    /// 图片的原始字节（内联用）。
    var imageData: Data?
    /// 文件本体的字节（上传用；上传成功后可以丢掉省内存）。
    var fileData: Data?
    var byteCount: Int
    var state: AttachmentState

    var isReady: Bool {
        switch state {
        case .ready, .uploaded: return true
        case .uploading, .failed: return false
        }
    }

    var progress: Double? {
        if case .uploading(let value) = state { return value }
        return nil
    }
}

enum AttachmentLimits {
    static let maxImageBytes = 20 * 1024 * 1024
    static let maxImagesPerMessage = 20
}

/// prompt 的 content 构造（可单测）。
enum PromptContentBuilder {
    /// text → `{"type":"text","text":…}`
    /// image → `{"type":"image","mediaType","data"(base64),"name"}`
    /// file  → `{"type":"file","receiptId"}`
    static func build(text: String, attachments: [ChatAttachment]) -> [JSONValue] {
        var content: [JSONValue] = []
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            content.append(.object(["type": .string("text"), "text": .string(trimmed)]))
        }
        for attachment in attachments {
            switch attachment.kind {
            case .image:
                guard let data = attachment.imageData, !data.isEmpty else { continue }
                var block: [String: JSONValue] = [
                    "type": .string("image"),
                    "mediaType": .string(attachment.mediaType ?? "image/png"),
                    "data": .string(data.base64EncodedString()),
                ]
                if !attachment.fileName.isEmpty { block["name"] = .string(attachment.fileName) }
                content.append(.object(block))
            case .file:
                guard case .uploaded(let receiptId) = attachment.state, !receiptId.isEmpty else { continue }
                content.append(.object(["type": .string("file"), "receiptId": .string(receiptId)]))
            }
        }
        return content
    }
}
