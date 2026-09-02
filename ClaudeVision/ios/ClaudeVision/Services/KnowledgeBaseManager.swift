import Foundation
import PDFKit
import Vision
import UIKit

@MainActor
class KnowledgeBaseManager: ObservableObject {
    @Published var manifests: [String: KBManifest] = [:]  // modeId -> manifest
    
    private let baseDir: URL
    
    // Common English stopwords to exclude from keyword indexing
    private static let stopwords: Set<String> = [
        "the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
        "have", "has", "had", "do", "does", "did", "will", "would", "could",
        "should", "may", "might", "shall", "can", "to", "of", "in", "for",
        "on", "with", "at", "by", "from", "as", "into", "through", "during",
        "before", "after", "above", "below", "between", "out", "off", "over",
        "under", "again", "further", "then", "once", "here", "there", "when",
        "where", "why", "how", "all", "each", "every", "both", "few", "more",
        "most", "other", "some", "such", "no", "nor", "not", "only", "own",
        "same", "so", "than", "too", "very", "just", "because", "but", "and",
        "or", "if", "while", "about", "up", "down", "it", "its", "this",
        "that", "these", "those", "i", "me", "my", "we", "our", "you", "your",
        "he", "him", "his", "she", "her", "they", "them", "their", "what",
        "which", "who", "whom"
    ]
    
    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.baseDir = docs.appendingPathComponent("KnowledgeBase", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        loadAllManifests()
    }
    
    // MARK: - Public API
    
    func documents(for modeId: String) -> [KBDocument] {
        manifests[modeId]?.documents ?? []
    }
    
    func totalChunks(for modeId: String) -> Int {
        manifests[modeId]?.chunks.count ?? 0
    }
    
    // MARK: - Import PDF
    
    func importPDF(url: URL, forMode modeId: String) async throws {
        guard url.startAccessingSecurityScopedResource() else {
            throw KBError.accessDenied
        }
        defer { url.stopAccessingSecurityScopedResource() }
        
        guard let pdf = PDFDocument(url: url) else {
            throw KBError.parseFailed("Could not open PDF")
        }
        
        var fullText = ""
        for i in 0..<pdf.pageCount {
            if let page = pdf.page(at: i), let text = page.string {
                fullText += text + "\n\n"
            }
        }
        
        guard !fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KBError.parseFailed("PDF contains no extractable text")
        }
        
        let name = url.lastPathComponent
        addDocument(name: name, modeId: modeId, sourceType: .pdf, text: fullText)
    }
    
    // MARK: - Import Text
    
    func importText(content: String, name: String, forMode modeId: String) {
        addDocument(name: name, modeId: modeId, sourceType: .text, text: content)
    }
    
    // MARK: - Import Image (OCR)
    
    func importImage(imageData: Data, name: String, forMode modeId: String) async throws {
        guard let cgImage = UIImage(data: imageData)?.cgImage else {
            throw KBError.parseFailed("Invalid image data")
        }
        
        let text = try await performOCR(on: cgImage)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KBError.parseFailed("No text found in image")
        }
        
        addDocument(name: name, modeId: modeId, sourceType: .image, text: text)
    }
    
    // MARK: - Import URL
    
    func importURL(_ urlString: String, forMode modeId: String) async throws {
        guard let url = URL(string: urlString) else {
            throw KBError.parseFailed("Invalid URL")
        }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let html = String(data: data, encoding: .utf8) else {
            throw KBError.parseFailed("Could not read URL content")
        }
        
        // Simple HTML stripping
        let text = stripHTML(html)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KBError.parseFailed("No text content at URL")
        }
        
        let name = url.host ?? urlString
        addDocument(name: name, modeId: modeId, sourceType: .url, text: text)
    }
    
    // MARK: - Delete Document
    
    func deleteDocument(id: UUID, modeId: String) {
        guard var manifest = manifests[modeId] else { return }
        manifest.documents.removeAll { $0.id == id }
        manifest.chunks.removeAll { $0.documentId == id }
        manifests[modeId] = manifest
        saveManifest(for: modeId)
    }
    
    // MARK: - Search (TF-IDF style keyword matching)
    
    func search(query: String, modeId: String, topK: Int = 5) -> [KBChunk] {
        guard let manifest = manifests[modeId], !manifest.chunks.isEmpty else { return [] }
        
        let queryTerms = extractKeywords(from: query)
        guard !queryTerms.isEmpty else { return [] }
        
        // Score each chunk by keyword overlap
        var scored: [(chunk: KBChunk, score: Double)] = []
        
        // Calculate IDF (inverse document frequency) for query terms
        let totalChunks = Double(manifest.chunks.count)
        var idf: [String: Double] = [:]
        for term in queryTerms {
            let docsWithTerm = manifest.chunks.filter { $0.keywords.contains(term) }.count
            if docsWithTerm > 0 {
                idf[term] = log(totalChunks / Double(docsWithTerm)) + 1.0
            }
        }
        
        for chunk in manifest.chunks {
            var score: Double = 0
            let chunkKeywordSet = Set(chunk.keywords)
            for term in queryTerms {
                if chunkKeywordSet.contains(term) {
                    // TF: count of term in chunk keywords
                    let tf = Double(chunk.keywords.filter { $0 == term }.count)
                    score += tf * (idf[term] ?? 1.0)
                }
            }
            if score > 0 {
                scored.append((chunk, score))
            }
        }
        
        // Return top K by score
        return scored
            .sorted { $0.score > $1.score }
            .prefix(topK)
            .map { $0.chunk }
    }
    
    // MARK: - Private: Document Processing
    
    private func addDocument(name: String, modeId: String, sourceType: KBSourceType, text: String) {
        let doc = KBDocument(
            name: name,
            modeId: modeId,
            sourceType: sourceType,
            chunkCount: 0,
            characterCount: text.count
        )
        
        let chunks = chunkText(text, documentId: doc.id, modeId: modeId)
        
        var updatedDoc = doc
        updatedDoc.chunkCount = chunks.count
        
        if manifests[modeId] == nil {
            manifests[modeId] = KBManifest()
        }
        manifests[modeId]?.documents.append(updatedDoc)
        manifests[modeId]?.chunks.append(contentsOf: chunks)
        
        saveManifest(for: modeId)
        print("[KB] Imported '\(name)' for mode '\(modeId)': \(chunks.count) chunks, \(text.count) chars")
    }
    
    // MARK: - Private: Text Chunking
    
    private func chunkText(_ text: String, documentId: UUID, modeId: String) -> [KBChunk] {
        let chunkSize = 2000   // ~500 tokens
        let overlap = 400      // ~100 tokens
        var chunks: [KBChunk] = []
        var start = text.startIndex
        var index = 0
        
        while start < text.endIndex {
            let endOffset = text.index(start, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            let chunkText = String(text[start..<endOffset])
            
            let keywords = extractKeywords(from: chunkText)
            let chunk = KBChunk(
                documentId: documentId,
                modeId: modeId,
                index: index,
                text: chunkText,
                keywords: keywords
            )
            chunks.append(chunk)
            index += 1
            
            // Advance by chunkSize - overlap
            let advance = max(chunkSize - overlap, 1)
            guard let nextStart = text.index(start, offsetBy: advance, limitedBy: text.endIndex) else { break }
            if nextStart >= text.endIndex { break }
            start = nextStart
        }
        
        return chunks
    }
    
    // MARK: - Private: Keyword Extraction
    
    private func extractKeywords(from text: String) -> [String] {
        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !Self.stopwords.contains($0) }
        return words
    }
    
    // MARK: - Private: OCR
    
    private func performOCR(on cgImage: CGImage) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                continuation.resume(returning: text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
    
    // MARK: - Private: HTML Stripping
    
    private func stripHTML(_ html: String) -> String {
        // Remove script and style blocks
        var text = html
        let patterns = ["<script[^>]*>[\\s\\S]*?</script>", "<style[^>]*>[\\s\\S]*?</style>"]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            }
        }
        // Remove all HTML tags
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        }
        // Decode common HTML entities
        text = text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        // Collapse whitespace
        if let regex = try? NSRegularExpression(pattern: "\\s+", options: []) {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Private: Persistence
    
    private func modeDir(for modeId: String) -> URL {
        let dir = baseDir.appendingPathComponent(modeId, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    
    private func saveManifest(for modeId: String) {
        guard let manifest = manifests[modeId] else { return }
        let url = modeDir(for: modeId).appendingPathComponent("manifest.json")
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: url, options: .atomic)
        }
    }
    
    private func loadAllManifests() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: baseDir, includingPropertiesForKeys: nil
        ) else { return }
        
        for dir in contents where dir.hasDirectoryPath {
            let modeId = dir.lastPathComponent
            let manifestURL = dir.appendingPathComponent("manifest.json")
            if let data = try? Data(contentsOf: manifestURL),
               let manifest = try? JSONDecoder().decode(KBManifest.self, from: data) {
                manifests[modeId] = manifest
                print("[KB] Loaded \(manifest.documents.count) docs, \(manifest.chunks.count) chunks for mode '\(modeId)'")
            }
        }
    }
}

// MARK: - Errors

enum KBError: LocalizedError {
    case accessDenied
    case parseFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .accessDenied: return "Cannot access the selected file"
        case .parseFailed(let msg): return msg
        }
    }
}
