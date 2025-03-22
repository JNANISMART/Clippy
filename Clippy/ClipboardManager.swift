import Foundation
import SwiftUI
import Combine

class ClipboardManager: ObservableObject {
    @Published var clipboardItems: [ClipboardItem] = []
    @Published var justCopied = false
    @Published var pinnedItems: [ClipboardItem] = []
    private weak var timer: Timer?
    private weak var autoDeleteTimer: Timer?
    private var pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private let maxItems = 30
    private var lastUpdateTime = Date()
    private let updateThreshold: TimeInterval = 0.2
    private let maxImageSize: Int = 1024 * 1024 * 5 // 5MB limit for images
    
    private var sensitiveContentPatterns: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"(?:\d[ -]*?){13,16}"#), // Credit card
        try! NSRegularExpression(pattern: #"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#), // Email
        try! NSRegularExpression(pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#) // IP address
    ]
    
    init() {
        lastChangeCount = pasteboard.changeCount
        loadSavedItems()
        startMonitoring()
        setupAutoDeleteTimer()
        
        // Listen for auto-delete setting changes
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("UpdateAutoDeleteSettings"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.setupAutoDeleteTimer()
        }
    }
    
    deinit {
        stopMonitoring()
        autoDeleteTimer?.invalidate()
        autoDeleteTimer = nil
    }
    
    func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkForChanges()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    
    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }
    
    private func checkForChanges() {
        let now = Date()
        if now.timeIntervalSince(lastUpdateTime) < updateThreshold {
            return
        }
        
        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }
        
        lastChangeCount = currentCount
        lastUpdateTime = now
        
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            
            if let url = self.pasteboard.string(forType: .string),
               let parsedURL = URL(string: url),
               parsedURL.scheme != nil {
                self.addItem(url: parsedURL)
            } else if let string = self.pasteboard.string(forType: .string) {
                self.addItem(string)
            } else if let image = self.pasteboard.data(forType: .tiff) {
                self.addItem(imageData: image)
            }
        }
    }
    
    func addItem(_ string: String) {
        guard !string.isEmpty else { return }
        if let firstItem = clipboardItems.first, firstItem.type == .text && firstItem.text == string {
            return
        }
        
        if UserDefaults.standard.bool(forKey: "detectSensitiveContent") && containsSensitiveData(string) {
            if UserDefaults.standard.bool(forKey: "skipSensitiveContent") {
                return
            }
            
            let maskedString = maskSensitiveContent(string)
            let newItem = ClipboardItem(text: maskedString, originalText: string)
            
            DispatchQueue.main.async {
                self.clipboardItems.insert(newItem, at: 0)
                if self.clipboardItems.count > self.maxItems {
                    self.clipboardItems.removeLast()
                }
                self.saveItems()
            }
        } else {
            let newItem = ClipboardItem(text: string)
            
            DispatchQueue.main.async {
                self.clipboardItems.insert(newItem, at: 0)
                if self.clipboardItems.count > self.maxItems {
                    self.clipboardItems.removeLast()
                }
                self.saveItems()
            }
        }
    }
    
    func addItem(imageData rawData: Data) {
        // Skip processing if the image is too large
        guard rawData.count <= maxImageSize else { return }
        
        // Optimize image data before storing
        let optimizedData = optimizeImageData(rawData)
        
        let newItem = ClipboardItem(imageData: optimizedData)
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.clipboardItems.insert(newItem, at: 0)
            if self.clipboardItems.count > self.maxItems {
                self.clipboardItems.removeLast()
            }
            self.saveItems()
        }
    }
    
    func addItem(url: URL) {
        let newItem = ClipboardItem(url: url)
        
        DispatchQueue.main.async {
            self.clipboardItems.insert(newItem, at: 0)
            if self.clipboardItems.count > self.maxItems {
                self.clipboardItems.removeLast()
            }
            self.saveItems()
        }
    }
    
    func copyItemToPasteboard(_ item: ClipboardItem) {
        pasteboard.clearContents()
        
        switch item.type {
        case .text:
            if let text = item.text {
                pasteboard.setString(text, forType: .string)
            }
        case .image:
            if let imageData = item.imageData {
                pasteboard.setData(imageData, forType: .tiff)
            }
        case .url:
            if let urlString = item.text {
                pasteboard.setString(urlString, forType: .string)
            }
        }
        
        DispatchQueue.main.async { [weak self] in
            print("Setting justCopied to true")
            self?.justCopied = true
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                print("Setting justCopied back to false")
                self?.justCopied = false
            }
        }
        
        if let index = clipboardItems.firstIndex(where: { $0.id == item.id }) {
            let movedItem = clipboardItems.remove(at: index)
            clipboardItems.insert(movedItem, at: 0)
            saveItems()
        }
    }
    
    private func saveItems() {
        let encoder = JSONEncoder()
        let textItems = clipboardItems.filter { $0.type != .image }.prefix(maxItems)
        
        DispatchQueue.global(qos: .background).async {
            if let encoded = try? encoder.encode(Array(textItems)) {
                UserDefaults.standard.set(encoded, forKey: "savedClipboardItems")
            }
        }
    }
    
    private func loadSavedItems() {
        if let savedData = UserDefaults.standard.data(forKey: "savedClipboardItems"),
           let loadedItems = try? JSONDecoder().decode([ClipboardItem].self, from: savedData) {
            clipboardItems = loadedItems
        }
        
        // Load pinned items
        if let savedData = UserDefaults.standard.data(forKey: "pinnedClipboardItems"),
           let loadedItems = try? JSONDecoder().decode([ClipboardItem].self, from: savedData) {
            pinnedItems = loadedItems
        }
    }
    
    func clearHistory() {
        clipboardItems.removeAll()
        saveItems()
    }
    
    private func optimizeImageData(_ data: Data) -> Data {
        if data.count <= maxImageSize {
            return data
        }
        
        if let image = NSImage(data: data),
           let downsampledData = image.downsample(to: CGSize(width: 800, height: 800)) {
            return downsampledData
        }
        
        return data
    }
    
    func togglePinStatus(_ item: ClipboardItem) {
        if let index = pinnedItems.firstIndex(where: { $0.id == item.id }) {
            // Unpin
            pinnedItems.remove(at: index)
        } else {
            // Pin
            pinnedItems.append(item)
            
            // Make sure we don't have too many pinned items
            if pinnedItems.count > 10 {
                pinnedItems.removeFirst()
            }
        }
        
        // Save pinned items
        savePinnedItems()
    }
    
    private func savePinnedItems() {
        let encoder = JSONEncoder()
        if let encoded = try? encoder.encode(pinnedItems) {
            UserDefaults.standard.set(encoded, forKey: "pinnedClipboardItems")
        }
    }
    
    private func containsSensitiveData(_ text: String) -> Bool {
        for pattern in sensitiveContentPatterns {
            let range = NSRange(location: 0, length: text.utf16.count)
            if pattern.firstMatch(in: text, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }
    
    private func maskSensitiveContent(_ text: String) -> String {
        var result = text
        
        for pattern in sensitiveContentPatterns {
            let range = NSRange(location: 0, length: text.utf16.count)
            let matches = pattern.matches(in: text, options: [], range: range)
            
            for match in matches.reversed() {
                if let range = Range(match.range, in: result) {
                    let replacement = String(repeating: "•", count: result[range].count)
                    result.replaceSubrange(range, with: replacement)
                }
            }
        }
        
        return result
    }
    
    func exportHistory() -> URL? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        
        guard let data = try? encoder.encode(clipboardItems.filter { $0.type != .image }) else {
            return nil
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("clipboard_history_\(Date().timeIntervalSince1970).json")
        
        do {
            try data.write(to: fileURL)
            return fileURL
        } catch {
            print("Failed to export: \(error)")
            return nil
        }
    }
    
    func importHistory(from url: URL) -> Bool {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let importedItems = try decoder.decode([ClipboardItem].self, from: data)
            
            DispatchQueue.main.async {
                // Add unique items to existing history
                let existingIds = Set(self.clipboardItems.map { $0.id })
                let newItems = importedItems.filter { !existingIds.contains($0.id) }
                
                self.clipboardItems.insert(contentsOf: newItems, at: 0)
                
                // Keep within max items limit
                if self.clipboardItems.count > self.maxItems {
                    self.clipboardItems = Array(self.clipboardItems.prefix(self.maxItems))
                }
                
                self.saveItems()
            }
            
            return true
        } catch {
            print("Failed to import: \(error)")
            return false
        }
    }
    
    func items(for category: ClipboardCategory) -> [ClipboardItem] {
        return clipboardItems.filter { $0.category == category }
    }
    
    func isPinned(_ item: ClipboardItem) -> Bool {
        return pinnedItems.contains(where: { $0.id == item.id })
    }
    
    func deleteItem(_ item: ClipboardItem) {
        if let index = clipboardItems.firstIndex(where: { $0.id == item.id }) {
            clipboardItems.remove(at: index)
            saveItems()
        }
        
        // Also remove from pinned items if it's pinned
        if let pinnedIndex = pinnedItems.firstIndex(where: { $0.id == item.id }) {
            pinnedItems.remove(at: pinnedIndex)
            savePinnedItems()
        }
    }
    
    private func setupAutoDeleteTimer() {
        // Clear any existing timer
        autoDeleteTimer?.invalidate()
        autoDeleteTimer = nil
        
        // Check if auto-delete is enabled
        let enableAutoDelete = UserDefaults.standard.bool(forKey: "enableAutoDelete")
        if !enableAutoDelete {
            return
        }
        
        // Set up timer to check for old items regularly
        autoDeleteTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.cleanupOldItems()
        }
        
        // Also clean up immediately
        cleanupOldItems()
    }
    
    private func cleanupOldItems() {
        // Only proceed if auto-delete is enabled
        let enableAutoDelete = UserDefaults.standard.bool(forKey: "enableAutoDelete")
        if !enableAutoDelete {
            return
        }
        
        // Get the auto-delete duration
        let autoDeleteDuration = UserDefaults.standard.integer(forKey: "autoDeleteDuration")
        if autoDeleteDuration <= 0 {
            return
        }
        
        let now = Date()
        var itemsDeleted = false
        
        // Filter out items that are older than the auto-delete duration
        // Don't delete pinned items
        clipboardItems = clipboardItems.filter { item in
            // Skip pinned items
            if pinnedItems.contains(where: { $0.id == item.id }) {
                return true
            }
            
            // Calculate the age of the item
            let itemAge = now.timeIntervalSince(item.timestamp)
            
            // Keep the item if it's newer than the auto-delete duration
            let shouldKeep = itemAge < Double(autoDeleteDuration)
            
            // Track if any items were deleted
            if !shouldKeep {
                itemsDeleted = true
            }
            
            return shouldKeep
        }
        
        // Save changes if any items were deleted
        if itemsDeleted {
            saveItems()
        }
    }
}

enum ClipboardItemType: String, Codable {
    case text
    case image
    case url
}

enum ClipboardCategory: String, Codable, CaseIterable {
    case text = "Text"
    case code = "Code"
    case url = "URLs"
    case image = "Images"
    
    var iconName: String {
        switch self {
        case .text: return "doc.text"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .url: return "link"
        case .image: return "photo"
        }
    }
    
    var color: Color {
        switch self {
        case .text: return .secondary
        case .code: return .blue
        case .url: return .green
        case .image: return .orange
        }
    }
}

struct ClipboardItem: Identifiable, Codable {
    let id = UUID()
    let timestamp = Date()
    let type: ClipboardItemType
    let text: String?
    let imageData: Data?
    let url: URL?
    let originalText: String?
    var category: ClipboardCategory?
    
    init(text: String, originalText: String? = nil) {
        if let url = URL(string: text), url.scheme != nil {
            self.type = .url
            self.text = text
            self.url = url
            self.imageData = nil
            self.originalText = originalText
            self.category = .url
        } else {
            self.type = .text
            self.text = text
            self.url = nil
            self.imageData = nil
            self.originalText = originalText
            
            // Detect if this is code
            if UserDefaults.standard.bool(forKey: "enableCategories") {
                self.category = self.detectedLanguage != nil ? .code : .text
            } else {
                self.category = nil
            }
        }
    }
    
    init(imageData: Data) {
        self.type = .image
        self.text = nil
        self.url = nil
        self.imageData = imageData
        self.originalText = nil
        self.category = .image
    }
    
    init(url: URL) {
        self.type = .url
        self.text = url.absoluteString
        self.url = url
        self.imageData = nil
        self.originalText = nil
        self.category = .url
    }
    
    var preview: String {
        switch type {
        case .text:
            let maxLength = 60
            if let text = text, text.count > maxLength {
                return String(text.prefix(maxLength)) + "..."
            }
            return text ?? ""
        case .image:
            return "[Image]"
        case .url:
            if let url = url {
                let displayString = url.host ?? url.absoluteString
                return displayString
            }
            return "[URL]"
        }
    }
    
    enum CodingKeys: String, CodingKey {
        case id, timestamp, type, text, imageData, url, originalText, category
    }
}

extension NSImage {
    func downsample(to targetSize: CGSize) -> Data? {
        let targetRect = CGRect(origin: .zero, size: targetSize)
        let newImage = NSImage(size: targetSize)
        
        newImage.lockFocus()
        draw(in: targetRect, from: .zero, operation: .copy, fraction: 1.0)
        newImage.unlockFocus()
        
        if let tiffData = newImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiffData) {
            return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        }
        
        return nil
    }
} 