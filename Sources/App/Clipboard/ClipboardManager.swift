//
//  ClipboardManager.swift
//  mkey
//
//  Clipboard history: polls NSPasteboard for new text *and images*, keeps a
//  capped ring buffer, persists it, and exposes a global hotkey to open the
//  picker. Images are stored as PNG files in Application Support; text and
//  metadata live in UserDefaults. Entirely separate from the engine.
//

import AppKit
import Carbon.HIToolbox
import Combine
import UniformTypeIdentifiers
import QuickLookThumbnailing

struct ClipItem: Identifiable, Codable, Equatable {
    let id: UUID
    let isImage: Bool
    let text: String        // text content, or a label like "Hình ảnh 1920×1080"
    let htmlText: String?    // HTML content for rich text items
    let imageFile: String?   // PNG filename (in the clipboard dir) for image items
    let filePath: String?    // original file path of the copied image file
    let filePaths: [String]? // original file paths of copied files
    let date: Date           // when it was captured
    let sourceApp: String?   // app that owned the clipboard at capture time

    init(text: String, htmlText: String? = nil, source: String?) {
        id = UUID(); isImage = false; self.text = text; self.htmlText = htmlText; imageFile = nil; filePath = nil; filePaths = nil; date = Date(); sourceApp = source
    }
    init(imageFile: String, label: String, filePath: String? = nil, source: String?) {
        id = UUID(); isImage = true; text = label; self.imageFile = imageFile; self.filePath = filePath; filePaths = nil; date = Date(); sourceApp = source; htmlText = nil
    }
    init(id: UUID, isImage: Bool, text: String, htmlText: String?, imageFile: String?, filePath: String?, filePaths: [String]?, date: Date, sourceApp: String?) {
        self.id = id
        self.isImage = isImage
        self.text = text
        self.htmlText = htmlText
        self.imageFile = imageFile
        self.filePath = filePath
        self.filePaths = filePaths
        self.date = date
        self.sourceApp = sourceApp
    }

    // Custom decode keeps backward compatibility with items saved before
    // date/sourceApp/filePath/htmlText/filePaths existed.
    enum CodingKeys: String, CodingKey { case id, isImage, text, htmlText, imageFile, filePath, filePaths, date, sourceApp }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        isImage = try c.decode(Bool.self, forKey: .isImage)
        text = try c.decode(String.self, forKey: .text)
        htmlText = try c.decodeIfPresent(String.self, forKey: .htmlText)
        imageFile = try c.decodeIfPresent(String.self, forKey: .imageFile)
        filePath = try c.decodeIfPresent(String.self, forKey: .filePath)
        filePaths = try c.decodeIfPresent([String].self, forKey: .filePaths)
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        sourceApp = try c.decodeIfPresent(String.self, forKey: .sourceApp)
    }
}

@MainActor
final class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager()

    // ⌃V default: keycode V (9), control bit (0x100), display char 'v' (0x76)
    static let defaultHotKey: Int32 = 0x7600_0109
    private static let maxImageBytes = 12 * 1024 * 1024

    private let defaults = UserDefaults.standard
    private let itemsKey = "clipboardItems"

    @Published var enabled: Bool {
        didSet {
            guard oldValue != enabled else { return }
            defaults.set(enabled, forKey: "clipboardHistoryEnabled")
            enabled ? start() : stop()
        }
    }

    @Published var hotKey: Int32 {
        didSet {
            guard oldValue != hotKey else { return }
            defaults.set(Int(hotKey), forKey: "clipboardHotKey")
            updateHotKeyRegistration()
        }
    }

    @Published var maxItems: Int {
        didSet {
            guard oldValue != maxItems else { return }
            defaults.set(maxItems, forKey: "clipboardMaxItems")
            trim()
        }
    }

    @Published var pinOnTop: Bool {
        didSet {
            guard oldValue != pinOnTop else { return }
            defaults.set(pinOnTop, forKey: "clipboardPickerPinOnTop")
            picker.updatePinOnTop(pinOnTop)
        }
    }

    @Published var autoHide: Bool {
        didSet {
            guard oldValue != autoHide else { return }
            defaults.set(autoHide, forKey: "clipboardPickerAutoHide")
            picker.updateAutoHide(autoHide)
        }
    }

    @Published var hasCustomLayout: Bool = false

    @Published private(set) var items: [ClipItem] = [] {
        didSet {
            picker.updateItems(items)
        }
    }

    private let pasteboard = NSPasteboard.general
    private var lastChangeCount: Int
    private var timer: Timer?
    private let hotKeyMonitor = GlobalHotKey()
    private let picker = ClipboardPicker()
    private let imageDir: URL

    private init() {
        defaults.register(defaults: [
            "clipboardHistoryEnabled": true,
            "clipboardMaxItems": 30,
            "clipboardPickerPinOnTop": true,
            "clipboardPickerAutoHide": true,
        ])
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        imageDir = appSupport.appendingPathComponent("MKey/clipboard", isDirectory: true)
        try? FileManager.default.createDirectory(at: imageDir, withIntermediateDirectories: true)

        enabled = defaults.bool(forKey: "clipboardHistoryEnabled")
        maxItems = max(10, min(100, defaults.integer(forKey: "clipboardMaxItems")))
        pinOnTop = defaults.bool(forKey: "clipboardPickerPinOnTop")
        autoHide = defaults.bool(forKey: "clipboardPickerAutoHide")
        let savedHotKey = Int32(truncatingIfNeeded: defaults.integer(forKey: "clipboardHotKey"))
        hotKey = savedHotKey == 0 ? ClipboardManager.defaultHotKey : savedHotKey
        lastChangeCount = pasteboard.changeCount
        loadItems()

        hotKeyMonitor.onPressed = { [weak self] in
            Task { @MainActor in self?.togglePicker() }
        }
        updateCustomLayoutStatus()
    }

    func imageURL(for item: ClipItem) -> URL? {
        guard let file = item.imageFile else { return nil }
        return imageDir.appendingPathComponent(file)
    }

    nonisolated private func generateQuickLookThumbnail(for fileURL: URL, size: CGSize) async -> NSImage? {
        await withCheckedContinuation { continuation in
            let request = QLThumbnailGenerator.Request(
                fileAt: fileURL,
                size: size,
                scale: 2.0,
                representationTypes: .thumbnail
            )
            QLThumbnailGenerator.shared.generateRepresentations(for: request) { (thumbnail, type, error) in
                if let nsImage = thumbnail?.nsImage {
                    continuation.resume(returning: nsImage)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: Lifecycle

    func startIfEnabled() { if enabled { start() } }

    private func start() {
        updateHotKeyRegistration()
        lastChangeCount = pasteboard.changeCount
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        hotKeyMonitor.unregister()
        picker.close()
    }

    private func updateHotKeyRegistration() {
        guard enabled else { hotKeyMonitor.unregister(); return }
        hotKeyMonitor.register(status: hotKey)
    }

    func suspendHotKey() {
        hotKeyMonitor.unregister()
    }

    func resumeHotKey() {
        updateHotKeyRegistration()
    }

    // MARK: Polling

    private func poll() {
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        if isSensitive() { return }

        let source = NSWorkspace.shared.frontmostApplication?.localizedName

        // Check for file URLs from Finder first
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            let fileURL = urls[0]
            let changeCountAtStart = pasteboard.changeCount
            Task.detached(priority: .background) {
                var pngData: Data? = nil
                
                // 1. Try generating a high-fidelity QuickLook thumbnail first
                if let qlImage = await ClipboardManager.shared.generateQuickLookThumbnail(for: fileURL, size: CGSize(width: 120, height: 120)) {
                    if let tiff = qlImage.tiffRepresentation,
                       let rep = NSBitmapImageRep(data: tiff) {
                        pngData = rep.representation(using: .png, properties: [:])
                    }
                }
                
                // 2. If QuickLook fails and it is a standard image, try reading the data directly
                if pngData == nil {
                    if let type = UTType(filenameExtension: fileURL.pathExtension), type.conforms(to: .image) {
                        if let data = try? Data(contentsOf: fileURL), data.count <= ClipboardManager.maxImageBytes {
                            if let rep = NSBitmapImageRep(data: data) {
                                pngData = rep.representation(using: .png, properties: [:])
                            } else {
                                pngData = data
                            }
                        }
                    }
                }
                
                // 3. Fallback to system file/folder icon
                if pngData == nil {
                    let icon = NSWorkspace.shared.icon(forFile: fileURL.path)
                    if let tiff = icon.tiffRepresentation,
                       let rep = NSBitmapImageRep(data: tiff) {
                        pngData = rep.representation(using: .png, properties: [:])
                    }
                }
                
                guard let png = pngData else { return }
                
                await MainActor.run {
                    guard ClipboardManager.shared.pasteboard.changeCount == changeCountAtStart else { return }
                    ClipboardManager.shared.addGeneralFiles(png, originalURLs: urls, source: source)
                }
            }
            return
        }

        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            let htmlText = pasteboard.string(forType: .html)
            addText(text, htmlText: htmlText, source: source)
            return
        }

        guard let types = pasteboard.types else { return }
        let hasImage = types.contains(.png) || types.contains(.tiff)
        if hasImage {
            var imgData: Data? = nil
            var isPNG = false
            if types.contains(.png), let png = pasteboard.data(forType: .png) {
                imgData = png
                isPNG = true
            } else if types.contains(.tiff), let tiff = pasteboard.data(forType: .tiff) {
                imgData = tiff
                isPNG = false
            }

            guard let data = imgData, data.count <= ClipboardManager.maxImageBytes else { return }
            let changeCountAtStart = pasteboard.changeCount

            Task.detached(priority: .background) {
                let pngToWrite: Data?
                if isPNG {
                    pngToWrite = data
                } else {
                    if let rep = NSBitmapImageRep(data: data) {
                        pngToWrite = rep.representation(using: .png, properties: [:])
                    } else {
                        pngToWrite = nil
                    }
                }

                guard let png = pngToWrite, png.count <= ClipboardManager.maxImageBytes else { return }

                await MainActor.run {
                    guard ClipboardManager.shared.pasteboard.changeCount == changeCountAtStart else { return }
                    ClipboardManager.shared.addImage(png, source: source)
                }
            }
        }
    }

    /// Skip password managers and apps that mark content as concealed/transient.
    private func isSensitive() -> Bool {
        guard let types = pasteboard.types else { return false }
        let names = types.map { $0.rawValue }
        let blocked = ["org.nspasteboard.ConcealedType",
                       "org.nspasteboard.TransientType",
                       "com.agilebits.onepassword",
                       "com.apple.is-sensitive"]
        return names.contains { blocked.contains($0) }
    }

    // MARK: Mutations

    private func addText(_ text: String, htmlText: String?, source: String?) {
        var next = items.filter { $0.isImage || $0.text != text } // dedupe identical text
        next.insert(ClipItem(text: text, htmlText: htmlText, source: source), at: 0)
        applyTrimmed(next)
    }

    private func addImage(_ png: Data, source: String?) {
        let filename = "\(UUID().uuidString).png"
        let url = imageDir.appendingPathComponent(filename)
        do { try png.write(to: url) } catch { return }

        let label: String
        if let rep = NSBitmapImageRep(data: png) {
            label = "Hình ảnh \(rep.pixelsWide)×\(rep.pixelsHigh)"
        } else {
            label = "Hình ảnh"
        }
        var next = items
        next.insert(ClipItem(imageFile: filename, label: label, source: source), at: 0)
        applyTrimmed(next)
    }

    private func addGeneralFiles(_ png: Data, originalURLs: [URL], source: String?) {
        let filename = "\(UUID().uuidString).png"
        let url = imageDir.appendingPathComponent(filename)
        do { try png.write(to: url) } catch { return }

        let label: String
        let count = originalURLs.count
        if count == 1 {
            let originalURL = originalURLs[0]
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: originalURL.path, isDirectory: &isDir), isDir.boolValue {
                label = "Thư mục: \(originalURL.lastPathComponent)"
            } else if let type = UTType(filenameExtension: originalURL.pathExtension) {
                if type.conforms(to: .image) {
                    label = "File ảnh: \(originalURL.lastPathComponent)"
                } else if type.conforms(to: .pdf) {
                    label = "File PDF: \(originalURL.lastPathComponent)"
                } else {
                    label = "File: \(originalURL.lastPathComponent)"
                }
            } else {
                label = "File: \(originalURL.lastPathComponent)"
            }
        } else {
            if count == 2 {
                label = "\(originalURLs[0].lastPathComponent), \(originalURLs[1].lastPathComponent)"
            } else {
                label = "\(originalURLs[0].lastPathComponent), \(originalURLs[1].lastPathComponent) và \(count - 2) tệp tin khác"
            }
        }

        var next = items
        let paths = originalURLs.map { $0.path }
        next = next.filter { $0.filePath != originalURLs[0].path }
        
        let newItem = ClipItem(
            id: UUID(),
            isImage: false,
            text: label,
            htmlText: nil,
            imageFile: filename,
            filePath: originalURLs[0].path,
            filePaths: paths,
            date: Date(),
            sourceApp: source
        )
        
        next.insert(newItem, at: 0)
        applyTrimmed(next)
    }

    /// Re-add an existing item to the top (after the user pastes it).
    private func promote(_ item: ClipItem) {
        var next = items.filter { $0.id != item.id }
        next.insert(item, at: 0)
        items = next
        persistItems()
    }

    private func applyTrimmed(_ newItems: [ClipItem]) {
        var next = newItems
        if next.count > maxItems {
            let dropped = next.suffix(next.count - maxItems)
            deleteImageFiles(of: dropped)
            next = Array(next.prefix(maxItems))
        }
        items = next
        persistItems()
    }

    private func trim() {
        guard items.count > maxItems else { return }
        deleteImageFiles(of: items.suffix(items.count - maxItems))
        items = Array(items.prefix(maxItems))
        persistItems()
    }

    func clear() {
        deleteImageFiles(of: items)
        items = []
        persistItems()
    }

    func remove(_ item: ClipItem) {
        deleteImageFiles(of: [item])
        items.removeAll { $0.id == item.id }
        persistItems()
    }

    func stripFormatting(of item: ClipItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        let oldItem = items[idx]
        
        var cleanPlainText = oldItem.text
        if let htmlText = oldItem.htmlText,
           let data = htmlText.data(using: .utf8),
           let attrStr = try? NSAttributedString(
               data: data,
               options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
               documentAttributes: nil
           ) {
            // NSAttributedString automatically removes HTML tags and extracts plain text
            cleanPlainText = attrStr.string
        }
        
        // Strip any remaining or explicit Markdown syntax to return pure plain text
        cleanPlainText = ClipboardManager.cleanMarkdown(cleanPlainText)
        
        let stripped = ClipItem(
            id: oldItem.id,
            isImage: oldItem.isImage,
            text: cleanPlainText,
            htmlText: nil,
            imageFile: oldItem.imageFile,
            filePath: oldItem.filePath,
            filePaths: oldItem.filePaths,
            date: oldItem.date,
            sourceApp: oldItem.sourceApp
        )
        items[idx] = stripped
        persistItems()
    }

    func resetPickerLayout() {
        defaults.removeObject(forKey: "clipboardPickerWidth")
        defaults.removeObject(forKey: "clipboardPickerHeight")
        defaults.removeObject(forKey: "clipboardPickerX")
        defaults.removeObject(forKey: "clipboardPickerY")
        updateCustomLayoutStatus()
        picker.resetLayout()
    }

    func updateCustomLayoutStatus() {
        let hasWidth = defaults.object(forKey: "clipboardPickerWidth") != nil
        let hasHeight = defaults.object(forKey: "clipboardPickerHeight") != nil
        let hasX = defaults.object(forKey: "clipboardPickerX") != nil
        let hasY = defaults.object(forKey: "clipboardPickerY") != nil
        hasCustomLayout = hasWidth || hasHeight || hasX || hasY
    }

    private func deleteImageFiles<S: Sequence>(of seq: S) where S.Element == ClipItem {
        for item in seq {
            if let url = imageURL(for: item) { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: Picker

    func togglePicker() {
        guard enabled else { return }
        picker.toggle(manager: self)
    }

    /// Put `item` on the clipboard and paste it into the previously focused app.
    func paste(_ item: ClipItem, into previousApp: NSRunningApplication?) {
        pasteboard.clearContents()
        
        var pbItems: [NSPasteboardItem] = []
        var hasData = false
        var activeFilePaths: [String] = []
        
        let isTargetFinder = previousApp?.bundleIdentifier == "com.apple.finder"
        
        if let filePaths = item.filePaths, !filePaths.isEmpty {
            activeFilePaths = filePaths.filter { FileManager.default.fileExists(atPath: $0) }
        } else if let filePath = item.filePath, FileManager.default.fileExists(atPath: filePath) {
            activeFilePaths = [filePath]
        }
        
        if activeFilePaths.isEmpty && isTargetFinder {
            if item.isImage, let url = imageURL(for: item) {
                let tempDir = FileManager.default.temporaryDirectory
                let timestamp = Int(Date().timeIntervalSince1970)
                let tempFileURL = tempDir.appendingPathComponent("Anh_Clipboard_\(timestamp).png")
                if let data = try? Data(contentsOf: url), (try? data.write(to: tempFileURL)) != nil {
                    activeFilePaths = [tempFileURL.path]
                }
            } else if !item.isImage {
                let tempDir = FileManager.default.temporaryDirectory
                let timestamp = Int(Date().timeIntervalSince1970)
                
                if let htmlText = item.htmlText,
                   let rtfData = ClipboardManager.convertHTMLToRTF(htmlText) {
                    let tempFileURL = tempDir.appendingPathComponent("Van_ban_Clipboard_\(timestamp).rtf")
                    if (try? rtfData.write(to: tempFileURL)) != nil {
                        activeFilePaths = [tempFileURL.path]
                    }
                }
                
                if activeFilePaths.isEmpty {
                    let tempFileURL = tempDir.appendingPathComponent("Van_ban_Clipboard_\(timestamp).txt")
                    if (try? item.text.write(to: tempFileURL, atomically: true, encoding: .utf8)) != nil {
                        activeFilePaths = [tempFileURL.path]
                    }
                }
            }
        }
        
        if !activeFilePaths.isEmpty {
            for path in activeFilePaths {
                let fileItem = NSPasteboardItem()
                let fileURL = URL(fileURLWithPath: path)
                fileItem.setString(fileURL.absoluteString, forType: .fileURL)
                fileItem.setPropertyList([path], forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
                pbItems.append(fileItem)
            }
            hasData = true
        }
        
        if item.isImage {
            if let url = imageURL(for: item), let data = try? Data(contentsOf: url) {
                let imageItem = NSPasteboardItem()
                imageItem.setData(data, forType: .png)
                if let image = NSImage(data: data), let tiffData = image.tiffRepresentation {
                    imageItem.setData(tiffData, forType: .tiff)
                }
                pbItems.append(imageItem)
                hasData = true
            }
        } else if activeFilePaths.isEmpty {
            let textItem = NSPasteboardItem()
            textItem.setString(item.text, forType: .string)
            if let htmlText = item.htmlText {
                textItem.setString(htmlText, forType: .html)
            }
            pbItems.append(textItem)
            hasData = true
        }
        
        if hasData {
            pasteboard.writeObjects(pbItems)
            if !activeFilePaths.isEmpty {
                pasteboard.setPropertyList(activeFilePaths, forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
            }
        } else {
            pasteboard.setString(item.text, forType: .string)
            if let htmlText = item.htmlText {
                pasteboard.setString(htmlText, forType: .html)
            }
        }
        
        lastChangeCount = pasteboard.changeCount
        promote(item)

        previousApp?.activate(options: .activateIgnoringOtherApps)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let src = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
            down?.flags = .maskCommand
            let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
            up?.flags = .maskCommand
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    private static func convertHTMLToRTF(_ html: String) -> Data? {
        guard let data = html.data(using: .utf8) else { return nil }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let attrStr = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return nil
        }
        return try? attrStr.data(
            from: NSRange(location: 0, length: attrStr.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    private static func cleanMarkdown(_ text: String) -> String {
        var result = text
        
        // 1. Remove bold/italic markup (**text**, *text*, __text__, _text_)
        result = result.replacingOccurrences(of: "\\*\\*|__", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\*|_", with: "", options: .regularExpression)
        
        // 2. Remove headers (### Text)
        result = result.replacingOccurrences(of: "(?m)^#{1,6}\\s+", with: "", options: .regularExpression)
        
        // 3. Remove inline code (`code`)
        result = result.replacingOccurrences(of: "`", with: "")
        
        // 4. Remove links [text](url) -> text
        result = result.replacingOccurrences(of: "\\[([^\\]]+)\\]\\(([^\\)]+)\\)", with: "$1", options: .regularExpression)
        
        // 5. Remove images ![alt](url) -> alt or empty
        result = result.replacingOccurrences(of: "!\\[([^\\]]*)\\]\\(([^\\)]+)\\)", with: "$1", options: .regularExpression)

        // 6. Remove horizontal lines (---, ***, ___)
        result = result.replacingOccurrences(of: "(?m)^[\\-*_]{3,}\\s*$", with: "", options: .regularExpression)
        
        return result
    }

    // MARK: Persistence

    private func loadItems() {
        guard let data = defaults.data(forKey: itemsKey),
              let decoded = try? JSONDecoder().decode([ClipItem].self, from: data) else { return }
        // keep only items whose backing image file still exists
        items = decoded.prefix(maxItems).filter { item in
            guard item.isImage else { return true }
            guard let url = imageURL(for: item) else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }

    private func persistItems() {
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: itemsKey)
        }
    }
}
