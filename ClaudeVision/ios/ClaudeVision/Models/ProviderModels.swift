import Foundation

/// The connection mode — either PC server or direct phone-to-API.
enum AppConnectionMode: String, Codable, CaseIterable, Identifiable {
    case channel = "Channel"    // Existing: PC server via WebSocket
    case direct = "Direct"      // New: Direct VLM API from phone
    case voiceCommand = "Voice Command" // PC server via WebSocket (voice only, no camera)
    var id: String { rawValue }
}

/// Supported VLM providers for Direct Mode.
enum VLMProvider: String, Codable, CaseIterable, Identifiable {
    case anthropic = "Anthropic"
    case gemini = "Google Gemini"
    case openai = "OpenAI"
    var id: String { rawValue }
    
    var iconName: String {
        switch self {
        case .anthropic: return "brain.head.profile"
        case .gemini: return "sparkles"
        case .openai: return "cpu"
        }
    }
    
    var brandColor: String {
        switch self {
        case .anthropic: return "#D3C3B1"
        case .gemini: return "#1A73E8"
        case .openai: return "#10A37F"
        }
    }
    
    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-4-20250514"
        case .gemini: return "gemini-2.5-flash"
        case .openai: return "gpt-4o"
        }
    }
}

struct ProviderModel: Identifiable, Codable, Hashable {
    let id: String           // e.g. "gemini-2.5-flash"
    let displayName: String  // e.g. "Gemini 2.5 Flash"
    let provider: VLMProvider
    let supportsVision: Bool
    let costTier: CostTier
    
    enum CostTier: String, Codable { case free, low, medium, high }
}

extension ProviderModel {
    static let anthropicModels: [ProviderModel] = [
        .init(id: "claude-sonnet-4-20250514", displayName: "Claude Sonnet 4", provider: .anthropic, supportsVision: true, costTier: .medium),
        .init(id: "claude-opus-4-20250514", displayName: "Claude Opus 4", provider: .anthropic, supportsVision: true, costTier: .high),
    ]
    static let geminiModels: [ProviderModel] = [
        .init(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash", provider: .gemini, supportsVision: true, costTier: .free),
        .init(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro", provider: .gemini, supportsVision: true, costTier: .medium),
    ]
    static let openaiModels: [ProviderModel] = [
        .init(id: "gpt-4o", displayName: "GPT-4o", provider: .openai, supportsVision: true, costTier: .medium),
        .init(id: "gpt-4o-mini", displayName: "GPT-4o Mini", provider: .openai, supportsVision: true, costTier: .low),
    ]
    
    static func models(for provider: VLMProvider) -> [ProviderModel] {
        switch provider {
        case .anthropic: return anthropicModels
        case .gemini: return geminiModels
        case .openai: return openaiModels
        }
    }
}
