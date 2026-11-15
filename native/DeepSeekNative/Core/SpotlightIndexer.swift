import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// 把会话写进系统 Spotlight，可以在聚焦搜索里直接搜到并打开
enum SpotlightIndexer {
  private static let domain = "sessions"
  static let identifierPrefix = "session-"

  static func reindex(_ sessions: [ChatSession]) {
    let index = CSSearchableIndex.default()
    let items: [CSSearchableItem] = sessions.prefix(50).map { session in
      let attributes = CSSearchableItemAttributeSet(contentType: .text)
      attributes.title = session.displayTitle
      attributes.contentDescription = session.preview
      attributes.keywords = ["DeepSeek", "对话", "AI"]
      return CSSearchableItem(
        uniqueIdentifier: identifierPrefix + session.id.uuidString,
        domainIdentifier: domain,
        attributeSet: attributes
      )
    }
    index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
      guard !items.isEmpty else { return }
      index.indexSearchableItems(items)
    }
  }

  /// 从 Spotlight 结果里还原会话 ID
  static func sessionID(from identifier: String) -> UUID? {
    guard identifier.hasPrefix(identifierPrefix) else { return nil }
    return UUID(uuidString: String(identifier.dropFirst(identifierPrefix.count)))
  }
}
