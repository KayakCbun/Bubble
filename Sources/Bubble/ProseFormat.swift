import Foundation

enum PathChipKind: Hashable {
    case code
    case file(String)
    case folder
    case url

    var isMonospaced: Bool {
        switch self {
        case .code, .file, .folder: return true
        case .url: return false
        }
    }

    var isFilePath: Bool {
        if case .file = self { return true }
        return false
    }
}

enum CodeDisplayChunker {
    static let targetCharacters = 6_000

    private static let cache: NSCache<NSString, CodeDisplayChunksBox> = {
        let cache = NSCache<NSString, CodeDisplayChunksBox>()
        cache.countLimit = 48
        cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()

    static func chunks(_ text: String, target: Int = targetCharacters) -> [String] {
        guard text.count > target else { return [text] }
        let key = "\(target):\(text)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached.chunks
        }
        let hardLimit = max(target + 1, target * 5 / 4)
        var chunks: [String] = []
        var start = text.startIndex
        var index = start
        var count = 0
        while index < text.endIndex {
            let character = text[index]
            index = text.index(after: index)
            count += 1
            if count >= target, character == "\n" || count >= hardLimit {
                chunks.append(String(text[start..<index]))
                start = index
                count = 0
            }
        }
        if start < text.endIndex {
            chunks.append(String(text[start...]))
        }
        let result = chunks.isEmpty ? [text] : chunks
        cache.setObject(CodeDisplayChunksBox(result), forKey: key, cost: text.utf8.count)
        return result
    }
}

private final class CodeDisplayChunksBox {
    let chunks: [String]

    init(_ chunks: [String]) {
        self.chunks = chunks
    }
}

enum InlineRun: Hashable {
    case text(String)
    case strong(String)
    case chip(String, PathChipKind)

    func replacingText(with text: String) -> InlineRun {
        switch self {
        case .text:
            return .text(text)
        case .strong:
            return .strong(text)
        case .chip:
            return self
        }
    }

    static func usesNativeTextLayout(_ runs: [InlineRun]) -> Bool {
        runs.allSatisfy { run in
            guard case .chip(_, let kind) = run else { return true }
            return kind == .code
        }
    }
}

/// A stable, value-only description of the typography that participates in a
/// transcript layout.  Keeping the fingerprint independent of SwiftUI's
/// `Font`/`Color` values means it can safely be used from the lock-protected
/// render cache and from background warm-up work.
struct ProseTypographyFingerprint: Hashable {
    var fontSizeMilliPoints: Int
    var weightMilli: Int
    var lineSpacingMilliPoints: Int
    var themeVersion: Int
    var displayScaleMilli: Int
    var layoutVersion: Int

    init(
        fontSize: Double,
        weight: Double,
        lineSpacing: Double,
        theme: Int = 1,
        displayScale: Double = 2,
        layoutVersion: Int = 1
    ) {
        fontSizeMilliPoints = Self.quantize(fontSize)
        weightMilli = Self.quantize(weight)
        lineSpacingMilliPoints = Self.quantize(lineSpacing)
        themeVersion = theme
        displayScaleMilli = Self.quantize(displayScale)
        self.layoutVersion = layoutVersion
    }

    /// MarkdownUI's parsed content tree is independent of font, width, color
    /// scheme, and display scale.  Use this neutral fingerprint when caching
    /// that tree so style changes do not create duplicate parse artifacts.
    static func contentOnly(layoutVersion: Int = 1) -> Self {
        Self(
            fontSize: 0,
            weight: 0,
            lineSpacing: 0,
            theme: 0,
            displayScale: 0,
            layoutVersion: layoutVersion
        )
    }

    private static func quantize(_ value: Double) -> Int {
        guard value.isFinite else { return 0 }
        return Int((value * 1_000).rounded())
    }
}

/// Content identity is deliberately exact in addition to carrying a stable
/// digest.  The text protects the cache from the practical consequences of a
/// digest collision while still allowing cache keys to be compared cheaply in
/// the hot path via their precomputed fields.
struct ProseContentFingerprint: Hashable {
    let text: String
    let digest: UInt64
    let byteCount: Int

    init(text: String) {
        self.text = text
        digest = Self.fnv1a(text.utf8)
        byteCount = text.utf8.count
    }

    init(runs: [InlineRun]) {
        var canonical = ""
        canonical.reserveCapacity(runs.reduce(into: 0) { $0 += $1.proseText.count + 2 })
        for run in runs {
            switch run {
            case .text(let value):
                canonical += "t:\(value)\u{1e}"
            case .strong(let value):
                canonical += "s:\(value)\u{1e}"
            case .chip(let value, let kind):
                canonical += "c:\(kind.proseTag):\(value)\u{1e}"
            }
        }
        self.init(text: canonical)
    }

    private static func fnv1a<S: Sequence>(_ bytes: S) -> UInt64 where S.Element == UInt8 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}

private extension InlineRun {
    var proseText: String {
        switch self {
        case .text(let value), .strong(let value), .chip(let value, _): return value
        }
    }
}

private extension PathChipKind {
    var proseTag: String {
        switch self {
        case .code: return "code"
        case .file(let ext): return "file:\(ext)"
        case .folder: return "folder"
        case .url: return "url"
        }
    }
}

/// The complete key for a prepared inline artifact or measured layout.
/// Width is quantized to half-point buckets so AppKit/SwiftUI's fractional
/// geometry updates do not create a new entry on every frame.
struct ProseRenderKey: Hashable {
    let content: ProseContentFingerprint
    let widthBucket: Int
    let typography: ProseTypographyFingerprint
    let variant: Int

    init(
        text: String,
        width: Double,
        typography: ProseTypographyFingerprint,
        variant: Int = 0
    ) {
        self.init(content: ProseContentFingerprint(text: text), width: width, typography: typography, variant: variant)
    }

    init(
        runs: [InlineRun],
        width: Double,
        typography: ProseTypographyFingerprint,
        variant: Int = 0
    ) {
        self.init(content: ProseContentFingerprint(runs: runs), width: width, typography: typography, variant: variant)
    }

    init(
        content: ProseContentFingerprint,
        width: Double,
        typography: ProseTypographyFingerprint,
        variant: Int = 0
    ) {
        self.content = content
        widthBucket = Self.quantizedWidthBucket(width)
        self.typography = typography
        self.variant = variant
    }

    var contentText: String { content.text }

    var quantizedWidth: Double {
        Double(widthBucket) / 2
    }

    static func quantizedWidthBucket(_ width: Double) -> Int {
        guard width.isFinite, width > 0 else { return 0 }
        return max(0, Int((width * 2).rounded()))
    }

    fileprivate var cacheToken: String {
        [
            String(content.digest, radix: 16),
            String(content.byteCount),
            String(widthBucket),
            String(typography.fontSizeMilliPoints),
            String(typography.weightMilli),
            String(typography.lineSpacingMilliPoints),
            String(typography.themeVersion),
            String(typography.displayScaleMilli),
            String(typography.layoutVersion),
            String(variant),
        ].joined(separator: ":")
    }
}

/// Prepared inline content is intentionally semantic.  The cache stores the
/// parsed AttributedString and run boundaries, but does not capture any
/// SwiftUI `Color` or environment object.  Visual colors are applied by the
/// view at render time, so theme changes invalidate via the fingerprint rather
/// than retaining thread-unsafe color values in a shared cache.
struct ProsePreparedInline: Equatable {
    let runs: [InlineRun]
    let attributedString: AttributedString
    let plainText: String
    let nativeTextLayout: Bool

    init(runs: [InlineRun], attributedString: AttributedString? = nil) {
        self.runs = runs
        plainText = runs.map { run in
            switch run {
            case .text(let value), .strong(let value), .chip(let value, _): return value
            }
        }.joined()
        self.attributedString = attributedString ?? AttributedString(plainText)
        nativeTextLayout = InlineRun.usesNativeTextLayout(runs)
    }

    var estimatedBytes: Int {
        // AttributedString's internal storage is implementation-defined.  A
        // conservative text/run estimate keeps the bounded cache from growing
        // without retaining the heavyweight SwiftUI view graph.
        max(128, plainText.utf8.count * 2) + runs.count * 64
    }
}

struct ProseMeasuredLayout: Equatable {
    var width: Double
    var height: Double
    var lineCount: Int
    var frames: [CGRect] = []

    var estimatedBytes: Int { 64 + frames.count * 64 }

    static func == (lhs: ProseMeasuredLayout, rhs: ProseMeasuredLayout) -> Bool {
        guard lhs.width == rhs.width,
              lhs.height == rhs.height,
              lhs.lineCount == rhs.lineCount,
              lhs.frames.count == rhs.frames.count
        else { return false }
        return zip(lhs.frames, rhs.frames).allSatisfy { left, right in
            left.origin.x == right.origin.x
                && left.origin.y == right.origin.y
                && left.size.width == right.size.width
                && left.size.height == right.size.height
        }
    }
}

private enum ProseRenderArtifact: Equatable {
    case inline(ProsePreparedInline)
    case measured(ProseMeasuredLayout)

    var estimatedBytes: Int {
        switch self {
        case .inline(let value): return value.estimatedBytes
        case .measured(let value): return value.estimatedBytes
        }
    }
}

private final class ProseRenderArtifactBox: NSObject {
    let value: Any
    let cost: Int

    init(value: Any, cost: Int) {
        self.value = value
        self.cost = cost
    }
}

/// A small LRU in front of NSCache.  NSCache provides automatic purging under
/// memory pressure; the explicit order/cost bookkeeping gives deterministic
/// count and byte bounds for normal operation and for focused checks.
final class ProseRenderCache {
    static let shared = ProseRenderCache(maxEntries: 512, maxEstimatedBytes: 16 * 1_024 * 1_024)

    private let maxEntries: Int
    private let maxEstimatedBytes: Int
    private let cache = NSCache<NSString, ProseRenderArtifactBox>()
    private let lock = NSLock()
    private var order: [String] = []
    private var costs: [String: Int] = [:]
    private var identities: [String: ProseRenderKey] = [:]
    private var totalCost = 0

    init(maxEntries: Int = 512, maxEstimatedBytes: Int = 16 * 1_024 * 1_024) {
        self.maxEntries = max(1, maxEntries)
        self.maxEstimatedBytes = max(1, maxEstimatedBytes)
        cache.countLimit = self.maxEntries
        cache.totalCostLimit = self.maxEstimatedBytes
        cache.evictsObjectsWithDiscardedContent = true
    }

    func preparedInline(
        for key: ProseRenderKey,
        completed: Bool,
        build: () -> ProsePreparedInline
    ) -> ProsePreparedInline {
        guard completed else { return build() }
        let token = "inline|\(key.cacheToken)"
        if let value = inlineValue(for: token, key: key) {
            return value
        }
        let built = build()
        insert(.inline(built), token: token, key: key)
        return built
    }

    func measuredLayout(
        for key: ProseRenderKey,
        completed: Bool,
        build: () -> ProseMeasuredLayout
    ) -> ProseMeasuredLayout {
        guard completed else { return build() }
        let token = "measured|\(key.cacheToken)"
        if let value = measuredValue(for: token, key: key) {
            return value
        }
        let built = build()
        insert(.measured(built), token: token, key: key)
        return built
    }

    /// Cache an artifact owned by another renderer (for example MarkdownUI's
    /// parsed `MarkdownContent`) without introducing a second cache policy.
    /// The value is opaque to this Foundation-only layer; the caller supplies
    /// its conservative byte estimate and keeps theme/style values out of the
    /// artifact itself.
    func cachedObject<Value>(
        for key: ProseRenderKey,
        variant: String,
        completed: Bool,
        estimatedBytes: Int,
        build: () -> Value
    ) -> Value {
        guard completed else { return build() }
        let token = "object|\(variant)|\(key.cacheToken)"
        if let box = object(for: token, key: key), let value = box.value as? Value {
            return value
        }
        let built = build()
        insertObject(
            built,
            token: token,
            key: key,
            estimatedBytes: estimatedBytes
        )
        return built
    }

    func contains(_ key: ProseRenderKey) -> Bool {
        let inline = "inline|\(key.cacheToken)"
        let measured = "measured|\(key.cacheToken)"
        lock.lock()
        defer { lock.unlock() }
        let inlineHit = identities[inline] == key && cache.object(forKey: inline as NSString) != nil
        let measuredHit = identities[measured] == key && cache.object(forKey: measured as NSString) != nil
        return inlineHit || measuredHit
    }

    var entryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        pruneMissingEntriesLocked()
        return order.count
    }

    var estimatedBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        pruneMissingEntriesLocked()
        return totalCost
    }

    func removeAll() {
        lock.lock()
        cache.removeAllObjects()
        order.removeAll(keepingCapacity: true)
        costs.removeAll(keepingCapacity: true)
        identities.removeAll(keepingCapacity: true)
        totalCost = 0
        lock.unlock()
    }

    private func inlineValue(for token: String, key: ProseRenderKey) -> ProsePreparedInline? {
        guard let artifact = object(for: token, key: key) else { return nil }
        guard let artifactValue = artifact.value as? ProseRenderArtifact,
              case .inline(let value) = artifactValue else { return nil }
        return value
    }

    private func measuredValue(for token: String, key: ProseRenderKey) -> ProseMeasuredLayout? {
        guard let artifact = object(for: token, key: key) else { return nil }
        guard let artifactValue = artifact.value as? ProseRenderArtifact,
              case .measured(let value) = artifactValue else { return nil }
        return value
    }

    private func object(for token: String, key renderKey: ProseRenderKey) -> ProseRenderArtifactBox? {
        lock.lock()
        defer { lock.unlock() }
        let cacheKey = token as NSString
        guard identities[token] == renderKey else {
            removeMetadataLocked(for: token)
            return nil
        }
        guard let box = cache.object(forKey: cacheKey) else {
            removeMetadataLocked(for: token)
            return nil
        }
        touchLocked(token)
        return box
    }

    private func insert(_ value: ProseRenderArtifact, token: String, key: ProseRenderKey) {
        insertObject(value, token: token, key: key, estimatedBytes: value.estimatedBytes)
    }

    private func insertObject(_ value: Any, token: String, key: ProseRenderKey, estimatedBytes: Int) {
        let cost = min(maxEstimatedBytes, max(1, estimatedBytes))
        let box = ProseRenderArtifactBox(value: value, cost: cost)
        lock.lock()
        if let previous = costs[token] {
            totalCost -= previous
            order.removeAll { $0 == token }
        }
        cache.setObject(box, forKey: token as NSString, cost: cost)
        costs[token] = cost
        identities[token] = key
        totalCost += cost
        order.append(token)
        trimLocked()
        lock.unlock()
    }

    private func trimLocked() {
        while order.count > maxEntries || totalCost > maxEstimatedBytes {
            guard let oldest = order.first else { break }
            order.removeFirst()
            let cost = costs.removeValue(forKey: oldest) ?? 0
            identities.removeValue(forKey: oldest)
            totalCost = max(0, totalCost - cost)
            cache.removeObject(forKey: oldest as NSString)
        }
    }

    private func touchLocked(_ token: String) {
        guard let index = order.firstIndex(of: token) else { return }
        order.remove(at: index)
        order.append(token)
    }

    private func removeMetadataLocked(for token: String) {
        guard costs.removeValue(forKey: token) != nil else { return }
        identities.removeValue(forKey: token)
        order.removeAll { $0 == token }
        totalCost = costs.values.reduce(0, +)
    }

    private func pruneMissingEntriesLocked() {
        let live = order.filter { cache.object(forKey: $0 as NSString) != nil }
        guard live.count != order.count else { return }
        order = live
        let liveSet = Set(live)
        costs = costs.filter { liveSet.contains($0.key) }
        identities = identities.filter { liveSet.contains($0.key) }
        totalCost = costs.values.reduce(0, +)
    }
}

enum MarkdownEmphasis {
    struct Span: Equatable {
        var inner: String
        var remainder: String
    }

    struct Boundaries: Equatable {
        var leading: String
        var core: String
        var trailing: String
    }

    static func boundaries(in text: String) -> Boundaries {
        let leading = text.prefix { $0.isWhitespace }
        let withoutLeading = text.dropFirst(leading.count)
        let trailing = withoutLeading.reversed().prefix { $0.isWhitespace }
        let core = withoutLeading.dropLast(trailing.count)
        return Boundaries(
            leading: String(leading),
            core: String(core),
            trailing: String(trailing.reversed())
        )
    }

    static func runs(for text: String) -> [InlineRun] {
        let parts = boundaries(in: text)
        guard !parts.core.isEmpty else { return [.text("**" + text + "**")] }
        var runs: [InlineRun] = []
        if !parts.leading.isEmpty { runs.append(.text(parts.leading)) }
        runs.append(.strong(parts.core))
        if !parts.trailing.isEmpty { runs.append(.text(parts.trailing)) }
        return runs
    }

    static func consumeLeading(in text: String) -> Span? {
        guard text.hasPrefix("**") else { return nil }
        let body = String(text.dropFirst(2))
        guard let end = body.range(of: "**") else { return nil }
        return Span(
            inner: String(body[..<end.lowerBound]),
            remainder: String(body[end.upperBound...])
        )
    }
}

enum CodeToken {
    static func looksLike(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if leading(text) == text { return true }
        if text.hasPrefix("<"), text.hasSuffix(">"), text.count <= 80 { return true }
        if isBracketTag(text) { return true }
        return false
    }

    static func leading(_ text: String) -> String? {
        guard let first = text.first else { return nil }
        if first == "<" { return leadingTag(text) }
        if first == "[" { return leadingBracketTag(text) }
        if text.hasPrefix("ou_") || text.hasPrefix("oc_") {
            return leadingPrefixedID(text)
        }
        if first == "/" { return leadingSlashCommand(text) }
        if isASCIILetter(first) { return leadingIdent(text) }
        if first.isNumber { return leadingNumber(text) }
        return nil
    }

    static func nextRange(in text: String) -> Range<String.Index>? {
        var index = text.startIndex
        var previous: Character = "\n"
        while index < text.endIndex {
            if isBoundary(previous) {
                let rest = String(text[index...])
                if let token = leading(rest) {
                    return index..<text.index(index, offsetBy: token.count)
                }
            }
            previous = text[index]
            index = text.index(after: index)
        }
        return nil
    }

    static func isBoundary(_ character: Character) -> Bool {
        if character.isWhitespace || character.isNewline { return true }
        if character == "`" || character == "*" { return true }
        if isCJK(character) { return true }
        return "，。、；：！？,.!?;:()（）[]【】{}<>《》\"“”‘’/\\|#=+~".contains(character)
    }

    private static func leadingTag(_ text: String) -> String? {
        guard text.first == "<" else { return nil }
        var end = text.index(after: text.startIndex)
        var count = 1
        while end < text.endIndex, count < 80 {
            let ch = text[end]
            if ch == "\n" { return nil }
            if ch == ">" {
                return String(text[text.startIndex...end])
            }
            end = text.index(after: end)
            count += 1
        }
        return nil
    }

    private static func isBracketTag(_ text: String) -> Bool {
        guard text.hasPrefix("["), text.hasSuffix("]"), text.count <= 24 else { return false }
        let inner = text.dropFirst().dropLast()
        guard inner.count >= 2 else { return false }
        if inner.contains(where: isCJK) { return true }
        return inner.range(of: "[A-Z]{2,}", options: .regularExpression) != nil
    }

    private static func leadingBracketTag(_ text: String) -> String? {
        guard text.first == "[" else { return nil }
        var end = text.index(after: text.startIndex)
        var count = 1
        while end < text.endIndex, count < 24 {
            let ch = text[end]
            if ch == "\n" { return nil }
            if ch == "]" {
                let token = String(text[text.startIndex...end])
                return isBracketTag(token) ? token : nil
            }
            end = text.index(after: end)
            count += 1
        }
        return nil
    }

    private static func leadingPrefixedID(_ text: String) -> String? {
        var end = text.startIndex
        var seenUnderscore = false
        while end < text.endIndex {
            let ch = text[end]
            if ch == "_" {
                seenUnderscore = true
                end = text.index(after: end)
                continue
            }
            if isASCIILetter(ch) || ch.isNumber {
                end = text.index(after: end)
                continue
            }
            break
        }
        let token = String(text[text.startIndex..<end])
        guard seenUnderscore, token.count >= 4 else { return nil }
        return token
    }

    private static func leadingSlashCommand(_ text: String) -> String? {
        guard text.first == "/" else { return nil }
        var end = text.index(after: text.startIndex)
        guard end < text.endIndex, isASCIILetter(text[end]) else { return nil }
        while end < text.endIndex {
            let ch = text[end]
            if isASCIILetter(ch) || ch.isNumber || ch == "_" || ch == "-" {
                end = text.index(after: end)
                continue
            }
            break
        }
        let token = String(text[text.startIndex..<end])
        return token.count >= 3 && token.count <= 24 ? token : nil
    }

    private static func leadingIdent(_ text: String) -> String? {
        var end = text.startIndex
        var underscores = 0
        var dots = 0
        while end < text.endIndex {
            let ch = text[end]
            if isASCIILetter(ch) || ch.isNumber {
                end = text.index(after: end)
                continue
            }
            if ch == "_" {
                underscores += 1
                end = text.index(after: end)
                continue
            }
            if ch == "." {
                let next = text.index(after: end)
                guard next < text.endIndex, isASCIILetter(text[next]) else { break }
                dots += 1
                end = next
                continue
            }
            break
        }
        let token = String(text[text.startIndex..<end])
        if underscores >= 1, dots == 0, token.count >= 3 { return token }
        if dots >= 2, token.count >= 5 { return token }
        return nil
    }

    private static func leadingNumber(_ text: String) -> String? {
        var end = text.startIndex
        while end < text.endIndex, text[end].isNumber {
            end = text.index(after: end)
        }
        let token = String(text[text.startIndex..<end])
        guard token.count >= 6 else { return nil }
        if end < text.endIndex, text[end] == "/" { return nil }
        return token
    }

    static func isCJK(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value)
                || (0x3400...0x4DBF).contains(scalar.value)
        }
    }

    private static func isASCIILetter(_ character: Character) -> Bool {
        character.isASCII && character.isLetter
    }
}

enum ProseWrap {
    static let cannotStartLine = CharacterSet(charactersIn: "，。、；：！？,.!?;:）)]》」』、%％°")

    static func cannotStart(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { cannotStartLine.contains($0) }
    }

    static func isGlueRun(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        return trimmed.allSatisfy(cannotStart)
    }

    static func glue(_ head: String, tail: String) -> (String, String) {
        var head = head
        var tail = tail
        while let first = tail.first, cannotStart(first) {
            head.append(first)
            tail.removeFirst()
        }
        while tail.first?.isWhitespace == true {
            tail.removeFirst()
        }
        return (head, tail)
    }
}

enum MarkdownMath {
    enum Part: Equatable {
        case text(String)
        case display(String)
    }

    static func blockExpression(from raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let delimiters = [("\\[", "\\]"), ("$$", "$$")]
        for (opening, closing) in delimiters where text.hasPrefix(opening) && text.hasSuffix(closing) {
            guard text.count >= opening.count + closing.count else { continue }
            let bodyStart = text.index(text.startIndex, offsetBy: opening.count)
            let bodyEnd = text.index(text.endIndex, offsetBy: -closing.count)
            let expression = text[bodyStart..<bodyEnd]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return expression.isEmpty ? nil : expression
        }
        return nil
    }

    static func splitBlocks(_ raw: String) -> [Part] {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        var parts: [Part] = []
        var prose: [String] = []
        var math: [String] = []
        var closing: String?
        var opening: String?

        func flushProse() {
            let text = prose.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { parts.append(.text(text)) }
            prose.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let expectedClose = closing {
                if trimmed == expectedClose {
                    let expression = math.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !expression.isEmpty { parts.append(.display(expression)) }
                    math.removeAll(keepingCapacity: true)
                    opening = nil
                    closing = nil
                } else {
                    math.append(line)
                }
                continue
            }
            if trimmed == "\\[" || trimmed == "$$" {
                flushProse()
                opening = trimmed
                closing = trimmed == "\\[" ? "\\]" : "$$"
                continue
            }
            if let expression = blockExpression(from: trimmed), trimmed != "\\[", trimmed != "$$" {
                flushProse()
                parts.append(.display(expression))
                continue
            }
            prose.append(line)
        }

        if let opening {
            prose.append(opening)
            prose.append(contentsOf: math)
        }
        flushProse()
        return parts.isEmpty ? [.text(raw)] : parts
    }

    static func typesetExpression(_ raw: String) -> String {
        var result = ""
        var cjk = ""
        var index = raw.startIndex

        func flushCJK() {
            guard !cjk.isEmpty else { return }
            result += "\\text{" + cjk + "}"
            cjk.removeAll(keepingCapacity: true)
        }

        while index < raw.endIndex {
            if raw[index...].hasPrefix("\\text{") {
                flushCJK()
                var depth = 0
                var sawBrace = false
                repeat {
                    let character = raw[index]
                    result.append(character)
                    if character == "{" {
                        sawBrace = true
                        depth += 1
                    }
                    if character == "}" { depth -= 1 }
                    index = raw.index(after: index)
                } while index < raw.endIndex && (!sawBrace || depth > 0)
                continue
            }
            let character = raw[index]
            if CodeToken.isCJK(character) {
                cjk.append(character)
            } else {
                flushCJK()
                result.append(character)
            }
            index = raw.index(after: index)
        }
        flushCJK()
        return result
    }

    static func nativeExpression(_ raw: String) -> String? {
        let operators = [
            "\\approx": "≈", "\\times": "×", "\\cdot": "·", "\\leq": "≤",
            "\\le": "≤", "\\geq": "≥", "\\ge": "≥", "\\neq": "≠",
            "\\pm": "±", "\\to": "→", "\\infty": "∞", "\\%": "%",
            "\\,": "", "\\;": " ",
        ]
        var text = raw
        for (latex, rendered) in operators {
            text = text.replacingOccurrences(of: latex, with: rendered)
        }
        guard !text.contains("\\") else { return nil }

        let superscripts: [Character: Character] = [
            "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
            "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
            "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        ]
        let subscripts: [Character: Character] = [
            "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
            "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
            "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
        ]
        var rendered = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "^" || character == "_" {
                let glyphs = character == "^" ? superscripts : subscripts
                let contentStart = text.index(after: index)
                guard contentStart < text.endIndex else { return nil }
                let content: Substring
                if text[contentStart] == "{" {
                    let valueStart = text.index(after: contentStart)
                    guard let close = text[valueStart...].firstIndex(of: "}") else { return nil }
                    content = text[valueStart..<close]
                    index = text.index(after: close)
                } else {
                    content = text[contentStart...contentStart]
                    index = text.index(after: contentStart)
                }
                for value in content {
                    guard let glyph = glyphs[value] else { return nil }
                    rendered.append(glyph)
                }
                continue
            }
            guard character != "{" && character != "}" else { return nil }
            rendered.append(character)
            index = text.index(after: index)
        }
        return rendered.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ProseReflow {
    private static let headingSuffixes = [
        "现象", "链路", "方案", "原因", "结论", "现状", "背景", "步骤",
        "分析", "概述", "总结", "进展", "状态", "说明", "建议", "处理",
        "排查", "问题", "清单", "结果", "详情", "摘要", "要点", "注意",
    ]

    static func reflow(_ raw: String) -> String {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        var out = ""
        var index = text.startIndex
        var lineStart = true

        func ensureBlankLine() {
            while out.hasSuffix("*") {
                out.removeLast()
            }
            while out.hasSuffix(" ") {
                out.removeLast()
            }
            if out.isEmpty || out.hasSuffix("\n\n") { return }
            if out.hasSuffix("\n") {
                out.append("\n")
            } else {
                out.append("\n\n")
            }
        }

        func ensureNewline() {
            while out.hasSuffix("*") {
                out.removeLast()
            }
            while out.hasSuffix(" ") {
                out.removeLast()
            }
            if out.isEmpty || out.hasSuffix("\n") { return }
            out.append("\n")
        }

        while index < text.endIndex {
            if text[index] == "`" {
                let (span, next) = consumeCodeSpan(text, from: index)
                out.append(span)
                index = next
                lineStart = false
                continue
            }
            if text[index] == "\n" {
                out.append("\n")
                index = text.index(after: index)
                lineStart = true
                continue
            }

            if lineStart, let table = consumePipeTable(text, from: index) {
                out.append(table.markup)
                index = table.next
                lineStart = true
                continue
            }

            if let heading = matchHeading(text, from: index) {
                if !lineStart { ensureBlankLine() }
                out.append(heading.markup)
                out.append("\n\n")
                index = heading.next
                lineStart = true
                continue
            }

            if let numbered = matchNumbered(text, from: index, lineStart: lineStart) {
                if !lineStart { ensureBlankLine() }
                out.append(numbered.markup)
                index = numbered.next
                lineStart = false
                continue
            }

            if let bullet = matchBullet(text, from: index, lineStart: lineStart) {
                if !lineStart { ensureNewline() }
                out.append(bullet.markup)
                index = bullet.next
                lineStart = false
                continue
            }

            if let rule = matchRule(text, from: index, lineStart: lineStart) {
                if !lineStart { ensureBlankLine() }
                out.append("---\n\n")
                index = rule
                lineStart = true
                continue
            }

            if let conclusion = matchConclusion(text, from: index, lineStart: lineStart) {
                ensureBlankLine()
                out.append(conclusion.markup)
                index = conclusion.next
                lineStart = false
                continue
            }

            out.append(text[index])
            lineStart = false
            index = text.index(after: index)
        }

        return out
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func consumeCodeSpan(_ text: String, from start: String.Index) -> (String, String.Index) {
        var fence = 0
        var index = start
        while index < text.endIndex, text[index] == "`" {
            fence += 1
            index = text.index(after: index)
        }
        let marker = String(repeating: "`", count: max(1, fence))
        if let end = text[index...].range(of: marker) {
            return (String(text[start..<end.upperBound]), end.upperBound)
        }
        return (String(text[start...]), text.endIndex)
    }

    private struct Piece {
        var markup: String
        var next: String.Index
    }

    private static func matchHeading(_ text: String, from start: String.Index) -> Piece? {
        let previous = prevCharacter(text, before: start)
        if let prev = previous,
           !prev.isWhitespace, !prev.isNewline, !isBreakBoundary(prev) {
            return nil
        }
        guard text[start] == "#" else { return nil }
        var index = start
        var level = 0
        while index < text.endIndex, text[index] == "#", level < 6 {
            level += 1
            index = text.index(after: index)
        }
        guard level > 0, index < text.endIndex else { return nil }
        let next = text[index]
        guard next.isWhitespace || next.isLetter || CodeToken.isCJK(next) else { return nil }
        while index < text.endIndex, text[index] == " " { index = text.index(after: index) }
        if previous == nil || previous?.isNewline == true {
            let lineEnd = text[index...].firstIndex(of: "\n") ?? text.endIndex
            let title = text[index..<lineEnd].trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return nil }
            return Piece(
                markup: String(repeating: "#", count: level) + " " + title,
                next: lineEnd
            )
        }
        let (title, bodyStart) = headingTitle(text, from: index)
        guard !title.isEmpty else { return nil }
        return Piece(markup: String(repeating: "#", count: level) + " " + title, next: bodyStart)
    }

    private static func headingTitle(_ text: String, from start: String.Index) -> (String, String.Index) {
        let rest = String(text[start...])
        if let structure = firstNearbyStructure(rest) {
            let title = String(rest[..<structure]).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty {
                return (title, text.index(start, offsetBy: rest.distance(from: rest.startIndex, to: structure)))
            }
        }
        if let paren = rest.range(of: #"^\p{Han}{2,12}[（(][^）)]{1,24}[）)]"#, options: .regularExpression) {
            let title = String(rest[paren])
            let after = String(rest[paren.upperBound...])
            if after.count >= 4 || firstNearbyStructure(after) != nil {
                return (title, text.index(start, offsetBy: rest.distance(from: rest.startIndex, to: paren.upperBound)))
            }
        }
        let prefix = String(rest.prefix(20))
        var best: String.Index?
        for suffix in headingSuffixes {
            if let range = prefix.range(of: suffix) {
                if best == nil || range.upperBound > best! {
                    best = range.upperBound
                }
            }
        }
        if let best, prefix.distance(from: prefix.startIndex, to: best) <= 16 {
            let title = String(prefix[prefix.startIndex..<best])
            let body = String(rest[best...])
            if body.count >= 6 {
                return (title, text.index(start, offsetBy: rest.distance(from: rest.startIndex, to: best)))
            }
        }
        var end = start
        var count = 0
        while end < text.endIndex, count < 24 {
            let ch = text[end]
            if ch == "\n" || ch == "#" { break }
            if ch == "。" || ch == "！" || ch == "？" { break }
            end = text.index(after: end)
            count += 1
        }
        let title = String(text[start..<end]).trimmingCharacters(in: .whitespaces)
        return (title, end)
    }

    private static func firstNearbyStructure(_ text: String) -> String.Index? {
        let window = String(text.prefix(36))
        if let numbered = window.range(of: #"\d{1,2}\.\s"#, options: .regularExpression) {
            if window.distance(from: window.startIndex, to: numbered.lowerBound) <= 24 {
                let prefix = window[..<numbered.lowerBound]
                if prefix.hasSuffix("**") {
                    return window.index(numbered.lowerBound, offsetBy: -2)
                }
                return numbered.lowerBound
            }
        }
        if let heading = window.range(of: "##") {
            if window.distance(from: window.startIndex, to: heading.lowerBound) <= 24 {
                return heading.lowerBound
            }
        }
        if let bullet = window.range(of: #"-(?:\s+|\p{Han}|\*\*)"#, options: .regularExpression) {
            if window.distance(from: window.startIndex, to: bullet.lowerBound) <= 24 {
                return bullet.lowerBound
            }
        }
        return nil
    }

    private static func matchNumbered(_ text: String, from start: String.Index, lineStart: Bool) -> Piece? {
        var index = start
        let boldTitle = peek(text, from: start, count: 2) == "**"
        if boldTitle {
            index = text.index(index, offsetBy: 2)
        } else if text[index] == "*" {
            while index < text.endIndex, text[index] == "*" {
                index = text.index(after: index)
            }
        }
        var digits = ""
        var cursor = index
        while cursor < text.endIndex, text[cursor].isNumber, digits.count < 2 {
            digits.append(text[cursor])
            cursor = text.index(after: cursor)
        }
        guard !digits.isEmpty, cursor < text.endIndex, text[cursor] == "." else { return nil }
        let afterDot = text.index(after: cursor)
        guard afterDot < text.endIndex else { return nil }
        let next = text[afterDot]
        guard next == " " || next == "*" || CodeToken.isCJK(next) || next.isLetter else { return nil }
        if !lineStart {
            if let prev = prevCharacter(text, before: start), !isBreakBoundary(prev) {
                return nil
            }
        }
        var consumed = afterDot
        if consumed < text.endIndex, text[consumed] == " " {
            consumed = text.index(after: consumed)
        }
        return Piece(markup: "\(digits). \(boldTitle ? "**" : "")", next: consumed)
    }

    private static func matchBullet(_ text: String, from start: String.Index, lineStart: Bool) -> Piece? {
        guard text[start] == "-" || text[start] == "*" else { return nil }
        if text[start] == "*" {
            if peek(text, from: start, count: 2).hasPrefix("**") { return nil }
            let after = text.index(after: start)
            guard after < text.endIndex, text[after] == " " else { return nil }
            if !lineStart, let prev = prevCharacter(text, before: start), prev == "*" || !isBreakBoundary(prev) {
                return nil
            }
            return Piece(markup: "- ", next: text.index(after: after))
        }
        let after = text.index(after: start)
        guard after < text.endIndex else { return nil }
        let next = text[after]
        let gluedHan = CodeToken.isCJK(next)
        let spaced = next == " " || next == "*"
        guard gluedHan || spaced else { return nil }
        if !lineStart {
            if let prev = prevCharacter(text, before: start) {
                let allowed = isBreakBoundary(prev) || CodeToken.isCJK(prev)
                if !allowed { return nil }
                var lookahead = after
                while lookahead < text.endIndex, text[lookahead] == " " {
                    lookahead = text.index(after: lookahead)
                }
                let afterSpaces = lookahead < text.endIndex ? text[lookahead] : " "
                if CodeToken.isCJK(prev), !gluedHan, afterSpaces != "*" { return nil }
            }
        }
        var consumed = after
        if consumed < text.endIndex, text[consumed] == " " {
            consumed = text.index(after: consumed)
        }
        return Piece(markup: "- ", next: consumed)
    }

    private static func consumePipeTable(_ text: String, from start: String.Index) -> Piece? {
        var cursor = start
        while cursor < text.endIndex, text[cursor] == " " || text[cursor] == "\t" {
            cursor = text.index(after: cursor)
        }
        guard cursor < text.endIndex, text[cursor] == "|" else { return nil }
        var index = start
        while index < text.endIndex {
            let lineStart = index
            while index < text.endIndex, text[index] == " " || text[index] == "\t" {
                index = text.index(after: index)
            }
            if index >= text.endIndex || text[index] != "|" {
                index = lineStart
                break
            }
            while index < text.endIndex, text[index] != "\n" {
                index = text.index(after: index)
            }
            if index < text.endIndex {
                index = text.index(after: index)
            }
        }
        let block = String(text[start..<index])
        guard block.contains("|") else { return nil }
        return Piece(markup: block, next: index)
    }

    private static func matchRule(_ text: String, from start: String.Index, lineStart: Bool) -> String.Index? {
        guard peek(text, from: start, count: 3) == "---" else { return nil }
        if !lineStart, let prev = prevCharacter(text, before: start), !isBreakBoundary(prev) {
            return nil
        }
        if let prev = prevNonSpace(text, before: start), prev == "|" {
            return nil
        }
        var index = text.index(start, offsetBy: 3)
        while index < text.endIndex, text[index] == "-" {
            index = text.index(after: index)
        }
        return index
    }

    private static func prevNonSpace(_ text: String, before index: String.Index) -> Character? {
        var i = index
        while i > text.startIndex {
            i = text.index(before: i)
            if text[i] != " " && text[i] != "\t" {
                return text[i]
            }
        }
        return nil
    }

    private static func matchConclusion(_ text: String, from start: String.Index, lineStart: Bool) -> Piece? {
        guard !lineStart else { return nil }
        let phrases = ["所以根因", "所以结论", "综上", "需要我帮你", "要继续往下"]
        for phrase in phrases {
            if peek(text, from: start, count: phrase.count) == phrase {
                if let prev = prevCharacter(text, before: start), prev.isNewline { return nil }
                return Piece(markup: phrase, next: text.index(start, offsetBy: phrase.count))
            }
        }
        return nil
    }

    private static func prevCharacter(_ text: String, before index: String.Index) -> Character? {
        guard index > text.startIndex else { return nil }
        return text[text.index(before: index)]
    }

    private static func isBreakBoundary(_ character: Character) -> Bool {
        if character.isWhitespace || character.isNewline { return true }
        return "，。、；：！？,.!?;:）)]》」』\"”’`".contains(character)
    }

    private static func peek(_ text: String, from start: String.Index, count: Int) -> String {
        let end = text.index(start, offsetBy: count, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[start..<end])
    }
}
