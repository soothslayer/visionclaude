import SwiftUI
import UniformTypeIdentifiers

struct KnowledgeBaseView: View {
    let mode: VisionMode
    @ObservedObject var kbManager: KnowledgeBaseManager
    @Environment(\.dismiss) private var dismiss
    @State private var showFilePicker = false
    @State private var showURLInput = false
    @State private var urlInput = ""
    @State private var importError: String?
    @State private var isImporting = false
    @State private var showTextInput = false
    @State private var textInputName = ""
    @State private var textInputContent = ""
    
    private let accentColor = Color(red: 232/255, green: 123/255, blue: 53/255)
    
    var body: some View {
        NavigationStack {
            List {
                // Stats section
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(mode.swiftColor.opacity(0.15))
                                .frame(width: 36, height: 36)
                            Image(systemName: "books.vertical.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(mode.swiftColor)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(documents.count) document\(documents.count == 1 ? "" : "s")")
                                .font(.headline)
                            Text("\(kbManager.totalChunks(for: mode.id)) chunks indexed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                } header: {
                    Label("Knowledge Base — \(mode.name)", systemImage: mode.icon)
                        .textCase(nil)
                        .font(.subheadline.weight(.semibold))
                }
                
                // Documents list
                if !documents.isEmpty {
                    Section {
                        ForEach(documents) { doc in
                            HStack(spacing: 12) {
                                Image(systemName: doc.sourceType.icon)
                                    .foregroundStyle(mode.swiftColor)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(doc.name)
                                        .font(.body)
                                        .lineLimit(1)
                                    HStack(spacing: 8) {
                                        Text("\(doc.chunkCount) chunks")
                                        Text("•")
                                        Text(formatSize(doc.characterCount))
                                        Text("•")
                                        Text(doc.addedDate, style: .date)
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete(perform: deleteDocuments)
                    } header: {
                        Text("Documents")
                    }
                }
                
                // Import actions
                Section {
                    Button {
                        showFilePicker = true
                    } label: {
                        Label("Import PDF or Text File", systemImage: "doc.badge.plus")
                    }
                    
                    Button {
                        showTextInput = true
                    } label: {
                        Label("Paste Text", systemImage: "doc.on.clipboard")
                    }
                    
                    Button {
                        showURLInput = true
                    } label: {
                        Label("Import from URL", systemImage: "link.badge.plus")
                    }
                } header: {
                    Text("Add Documents")
                } footer: {
                    Text("Upload service manuals, spec sheets, or reference docs. The app will chunk and index them for retrieval when you ask questions in \(mode.name) mode.")
                }
                
                // Import status
                if isImporting {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Processing document...")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                if let error = importError {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                            Text(error)
                                .font(.subheadline)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("📚 Knowledge Base")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.pdf, .plainText, .utf8PlainText],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
            .alert("Import from URL", isPresented: $showURLInput) {
                TextField("https://...", text: $urlInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Import") {
                    Task { await importFromURL() }
                }
                Button("Cancel", role: .cancel) { urlInput = "" }
            } message: {
                Text("Enter the URL of a web page to import as reference documentation.")
            }
            .sheet(isPresented: $showTextInput) {
                NavigationStack {
                    Form {
                        TextField("Document Name", text: $textInputName)
                        Section("Content") {
                            TextEditor(text: $textInputContent)
                                .frame(minHeight: 200)
                        }
                    }
                    .navigationTitle("Paste Text")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                showTextInput = false
                                textInputName = ""
                                textInputContent = ""
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Add") {
                                let name = textInputName.isEmpty ? "Pasted Text" : textInputName
                                kbManager.importText(content: textInputContent, name: name, forMode: mode.id)
                                showTextInput = false
                                textInputName = ""
                                textInputContent = ""
                            }
                            .disabled(textInputContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Computed
    
    private var documents: [KBDocument] {
        kbManager.documents(for: mode.id)
    }
    
    // MARK: - Actions
    
    private func deleteDocuments(at offsets: IndexSet) {
        for index in offsets {
            let doc = documents[index]
            kbManager.deleteDocument(id: doc.id, modeId: mode.id)
        }
    }
    
    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            isImporting = true
            importError = nil
            Task {
                do {
                    if url.pathExtension.lowercased() == "pdf" {
                        try await kbManager.importPDF(url: url, forMode: mode.id)
                    } else {
                        let content = try String(contentsOf: url, encoding: .utf8)
                        kbManager.importText(content: content, name: url.lastPathComponent, forMode: mode.id)
                    }
                } catch {
                    importError = error.localizedDescription
                }
                isImporting = false
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }
    
    private func importFromURL() async {
        guard !urlInput.isEmpty else { return }
        isImporting = true
        importError = nil
        do {
            try await kbManager.importURL(urlInput, forMode: mode.id)
        } catch {
            importError = error.localizedDescription
        }
        isImporting = false
        urlInput = ""
    }
    
    private func formatSize(_ chars: Int) -> String {
        if chars < 1000 { return "\(chars) chars" }
        if chars < 1_000_000 { return String(format: "%.1fK chars", Double(chars) / 1000) }
        return String(format: "%.1fM chars", Double(chars) / 1_000_000)
    }
}
