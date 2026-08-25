import Foundation

class DirectVLMClient: VLMService {
    var isConnected: Bool = false
    
    var onReply: ((String, String?) -> Void)?
    var onStatus: ((String) -> Void)?
    var onThinking: ((String) -> Void)?
    var onDisconnect: (() -> Void)?
    var onError: ((String) -> Void)?
    
    private var provider: VLMProvider
    private var model: String
    private var apiKey: String? {
        KeychainHelper.shared.load(forKey: "vlm_\(provider.rawValue)")
    }
    
    init(config: ClaudeConfig) {
        self.provider = config.vlmProvider
        self.model = config.selectedModelId
    }
    
    func updateConfig(_ config: ClaudeConfig) {
        self.provider = config.vlmProvider
        self.model = config.selectedModelId
    }
    
    func testConnection() async throws {
        guard let key = apiKey, !key.isEmpty else {
            throw NSError(domain: "DirectVLM", code: 0, userInfo: [NSLocalizedDescriptionKey: "No API key set for \(provider.rawValue)"])
        }
        // Simple test: send a minimal request
        let _ = try await performRequest(key: key, text: "Say hello in one word.", imageData: nil, systemPrompt: nil, history: [])
    }

    
    func connect() async {
        isConnected = true
        onStatus?("Connected to \(provider.rawValue)")
    }
    
    func disconnect() {
        isConnected = false
        onDisconnect?()
    }
    
    func resetConversation() {
        // Handled externally by callers passing history
    }
    
    func sendMessage(text: String, imageData: Data?, systemPrompt: String?, history: [TranscriptMessage]) async {
        guard let key = apiKey, !key.isEmpty else {
            onError?("Missing API Key for \(provider.rawValue)")
            return
        }
        
        onThinking?("Calling \(provider.rawValue)...")
        
        do {
            let responseText = try await performRequest(key: key, text: text, imageData: imageData, systemPrompt: systemPrompt, history: history)
            onReply?(responseText, nil)
        } catch {
            print("[DirectVLM] Error: \(error)")
            onError?(error.localizedDescription)
        }
    }
    
    private func performRequest(key: String, text: String, imageData: Data?, systemPrompt: String?, history: [TranscriptMessage]) async throws -> String {
        switch provider {
        case .anthropic:
            return try await callAnthropic(key: key, text: text, imageData: imageData, systemPrompt: systemPrompt, history: history)
        case .gemini:
            return try await callGemini(key: key, text: text, imageData: imageData, systemPrompt: systemPrompt, history: history)
        case .openai:
            return try await callOpenAI(key: key, text: text, imageData: imageData, systemPrompt: systemPrompt, history: history)
        }
    }
    
    // MARK: - Anthropic
    private func callAnthropic(key: String, text: String, imageData: Data?, systemPrompt: String?, history: [TranscriptMessage]) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue(key, forHTTPHeaderField: "x-api-key")
        request.addValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.addValue("application/json", forHTTPHeaderField: "content-type")
        
        var messages: [[String: Any]] = []
        for msg in history {
            messages.append([
                "role": msg.role == .user ? "user" : "assistant",
                "content": msg.text
            ])
        }
        
        var currentUserContent: [[String: Any]] = []
        if let imgData = imageData {
            currentUserContent.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": imgData.base64EncodedString()
                ]
            ])
        }
        currentUserContent.append([
            "type": "text",
            "text": text
        ])
        
        messages.append([
            "role": "user",
            "content": currentUserContent
        ])
        
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": messages
        ]
        
        if let sys = systemPrompt, !sys.isEmpty {
            body["system"] = sys
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpRes = response as? HTTPURLResponse, (200...299).contains(httpRes.statusCode) else {
            let errString = String(data: data, encoding: .utf8) ?? "Unknown Error"
            throw NSError(domain: "AnthropicError", code: 0, userInfo: [NSLocalizedDescriptionKey: errString])
        }
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let content = json?["content"] as? [[String: Any]], let first = content.first, let respText = first["text"] as? String {
            return respText
        }
        
        throw NSError(domain: "AnthropicError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format"])
    }
    
    // MARK: - Gemini
    private func callGemini(key: String, text: String, imageData: Data?, systemPrompt: String?, history: [TranscriptMessage]) async throws -> String {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(key)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var contents: [[String: Any]] = []
        for msg in history {
            contents.append([
                "role": msg.role == .user ? "user" : "model",
                "parts": [["text": msg.text]]
            ])
        }
        
        var currentUserParts: [[String: Any]] = []
        if let imgData = imageData {
            currentUserParts.append([
                "inlineData": [
                    "mimeType": "image/jpeg",
                    "data": imgData.base64EncodedString()
                ]
            ])
        }
        currentUserParts.append([
            "text": text
        ])
        
        contents.append([
            "role": "user",
            "parts": currentUserParts
        ])
        
        var body: [String: Any] = [
            "contents": contents
        ]
        
        if let sys = systemPrompt, !sys.isEmpty {
            body["system_instruction"] = [
                "parts": [["text": sys]]
            ]
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpRes = response as? HTTPURLResponse, (200...299).contains(httpRes.statusCode) else {
            let errString = String(data: data, encoding: .utf8) ?? "Unknown Error"
            throw NSError(domain: "GeminiError", code: 0, userInfo: [NSLocalizedDescriptionKey: errString])
        }
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let candidates = json?["candidates"] as? [[String: Any]], let first = candidates.first,
           let content = first["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]],
           let respText = parts.first?["text"] as? String {
            return respText
        }
        
        throw NSError(domain: "GeminiError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format"])
    }
    
    // MARK: - OpenAI
    private func callOpenAI(key: String, text: String, imageData: Data?, systemPrompt: String?, history: [TranscriptMessage]) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var messages: [[String: Any]] = []
        if let sys = systemPrompt, !sys.isEmpty {
            messages.append([
                "role": "system",
                "content": sys
            ])
        }
        
        for msg in history {
            messages.append([
                "role": msg.role == .user ? "user" : "assistant",
                "content": msg.text
            ])
        }
        
        var currentUserContent: [[String: Any]] = []
        if let imgData = imageData {
            currentUserContent.append([
                "type": "image_url",
                "image_url": [
                    "url": "data:image/jpeg;base64,\(imgData.base64EncodedString())"
                ]
            ])
        }
        currentUserContent.append([
            "type": "text",
            "text": text
        ])
        
        messages.append([
            "role": "user",
            "content": currentUserContent
        ])
        
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": messages
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpRes = response as? HTTPURLResponse, (200...299).contains(httpRes.statusCode) else {
            let errString = String(data: data, encoding: .utf8) ?? "Unknown Error"
            throw NSError(domain: "OpenAIError", code: 0, userInfo: [NSLocalizedDescriptionKey: errString])
        }
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let choices = json?["choices"] as? [[String: Any]], let first = choices.first,
           let message = first["message"] as? [String: Any], let respText = message["content"] as? String {
            return respText
        }
        
        throw NSError(domain: "OpenAIError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid response format"])
    }
}
