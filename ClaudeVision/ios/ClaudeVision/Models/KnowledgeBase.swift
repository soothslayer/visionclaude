import Foundation

// MARK: - Knowledge Base Source Type

enum KBSourceType: String, Codable {
    case pdf
    case text
    case image
    case url
    
    var icon: String {
        switch self {
        case .pdf: return "doc.fill"
        case .text: return "doc.text.fill"
        case .image: return "photo.fill"
        case .url: return "link"
        }
    }
}

// MARK: - Knowledge Base Document

struct KBDocument: Identifiable, Codable {
    let id: UUID
    let name: String
    let modeId: String
    let addedDate: Date
    let sourceType: KBSourceType
    var chunkCount: Int
    var characterCount: Int
    
    init(name: String, modeId: String, sourceType: KBSourceType, chunkCount: Int = 0, characterCount: Int = 0) {
        self.id = UUID()
        self.name = name
        self.modeId = modeId
        self.addedDate = Date()
        self.sourceType = sourceType
        self.chunkCount = chunkCount
        self.characterCount = characterCount
    }
}

// MARK: - Knowledge Base Chunk

struct KBChunk: Identifiable, Codable {
    let id: UUID
    let documentId: UUID
    let modeId: String
    let index: Int
    let text: String
    let keywords: [String]
    
    init(documentId: UUID, modeId: String, index: Int, text: String, keywords: [String]) {
        self.id = UUID()
        self.documentId = documentId
        self.modeId = modeId
        self.index = index
        self.text = text
        self.keywords = keywords
    }
}

// MARK: - Knowledge Base Manifest (persisted per mode)

struct KBManifest: Codable {
    var documents: [KBDocument]
    var chunks: [KBChunk]
    
    init() {
        self.documents = []
        self.chunks = []
    }
}
