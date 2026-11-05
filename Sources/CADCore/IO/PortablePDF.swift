import Foundation

/// Reads the vector paths and images of a PDF's first page without Core Graphics, for Windows and Linux. The Mac app keeps
/// `CGPDFScanner`; this compiles there too so a test can hold the two to the same result on the same files.
///
/// It covers what vector PDFs from design software hold: classic and compressed (object stream) files, FlateDecode, ASCII85 and
/// ASCIIHex filters, q/Q/cm, paths and paint operators, Form XObjects, and JPEG or 8-bit raw images. Encrypted files are refused.
struct PortablePDF {
    typealias Dictionary = [String: Object]

    indirect enum Object {
        case null, bool(Bool), number(Double), name(String), string([UInt8]), array([Object]), dict(Dictionary), reference(Int), stream(Dictionary, [UInt8])

        var number: Double? { if case .number(let v) = self { return v } else { return nil } }
        var name: String? { if case .name(let v) = self { return v } else { return nil } }
        var array: [Object]? { if case .array(let v) = self { return v } else { return nil } }
    }

    struct Failure: Error { var message: String }

    private var objects: [Int: Object] = [:]
    private let bytes: [UInt8]

    init(data: Data) throws {
        bytes = [UInt8](data)
        guard bytes.count > 8, Self.find(Array("%PDF-".utf8), in: bytes, from: 0, upTo: min(bytes.count, 1024)) != nil else {
            throw Failure(message: "PDF: not a readable PDF document")
        }
        scanObjects()
        if objects.isEmpty { throw Failure(message: "PDF: not a readable PDF document") }
        expandObjectStreams()
        if Self.find(Array("/Encrypt".utf8), in: bytes, from: 0, upTo: bytes.count) != nil {
            throw Failure(message: "PDF: the document is password protected")
        }
    }

    // MARK: Objects

    func resolve(_ object: Object?) -> Object {
        var current = object ?? .null
        var hops = 0
        while case .reference(let n) = current, hops < 32 {
            current = objects[n] ?? .null
            hops += 1
        }
        if case .reference = current { return .null }
        return current
    }

    func dict(_ object: Object?) -> Dictionary? {
        switch resolve(object) {
        case .dict(let d), .stream(let d, _): return d
        default: return nil
        }
    }

    /// Every `n g obj` in the file. The last definition of a number wins, which is what an incremental update means, so the cross
    /// reference table isn't needed, and a damaged one doesn't matter.
    private mutating func scanObjects() {
        let marker = Array("obj".utf8)
        var i = 0
        while let at = Self.find(marker, in: bytes, from: i, upTo: bytes.count) {
            i = at + 3
            if at >= 3, bytes[at - 3] == 0x65, bytes[at - 2] == 0x6E, bytes[at - 1] == 0x64 { continue }   // endobj
            guard let number = Self.objectNumber(before: at, in: bytes) else { continue }
            var lexer = Lexer(bytes: bytes, position: at + 3)
            guard let object = lexer.object() else { continue }
            if case .dict(let d) = object, let start = lexer.streamStart() {
                let end = streamEnd(dict: d, start: start)
                objects[number] = .stream(d, Array(bytes[start..<end]))
                i = end
            } else {
                objects[number] = object
                i = max(i, lexer.position)
            }
        }
    }

    private func streamEnd(dict d: Dictionary, start: Int) -> Int {
        if case .number(let n)? = d["Length"], let length = Self.int(n), length >= 0, length <= bytes.count - start {
            let end = start + length
            // Trust the length only when endstream follows it: a wrong length is common.
            if Self.find(Array("endstream".utf8), in: bytes, from: end, upTo: min(end + 16, bytes.count)) != nil { return end }
        }
        return Self.find(Array("endstream".utf8), in: bytes, from: start, upTo: bytes.count) ?? bytes.count
    }

    private mutating func expandObjectStreams() {
        for (_, object) in objects {
            guard case .stream(let d, _) = object, d["Type"]?.name == "ObjStm", let data = decoded(object),
                  let n = Self.int(resolve(d["N"]).number), n >= 0, let first = Self.int(resolve(d["First"]).number), first >= 0, first <= data.count
            else { continue }
            var header = Lexer(bytes: data, position: 0)
            for _ in 0..<n {
                guard case .number(let number)? = header.object(), case .number(let offset)? = header.object(),
                      let id = Self.int(number), let at = Self.int(offset), at >= 0, at <= data.count - first else { break }
                var body = Lexer(bytes: data, position: first + at)
                if objects[id] == nil, let inner = body.object() { objects[id] = inner }
            }
        }
    }

    /// The stream's bytes through its filters, or nil when a filter isn't supported (DCT stays encoded: `format` says so).
    func decoded(_ object: Object) -> [UInt8]? {
        guard case .stream(let d, var data) = object else { return nil }
        let filter = resolve(d["Filter"] ?? d["F"])
        let names: [String]
        switch filter {
        case .name(let n): names = [n]
        case .array(let a): names = a.compactMap { resolve($0).name }
        default: names = []
        }
        let parms: [Object]
        switch resolve(d["DecodeParms"]) {
        case .array(let a): parms = a
        case .null: parms = []
        case let single: parms = [single]
        }
        for (i, name) in names.enumerated() {
            switch name {
            case "FlateDecode", "Fl":
                guard let out = Inflate.zlib(data) else { return nil }
                data = out
                if i < parms.count, let p = dict(parms[i]), let predictor = resolve(p["Predictor"]).number, predictor > 1 {
                    guard let predictorID = Self.int(predictor), let columns = Self.int(resolve(p["Columns"]).number ?? 1),
                          let colors = Self.int(resolve(p["Colors"]).number ?? 1), let bits = Self.int(resolve(p["BitsPerComponent"]).number ?? 8),
                          let undone = Self.undoPredictor(data, predictor: predictorID, columns: columns, colors: colors, bits: bits) else { return nil }
                    data = undone
                }
            case "ASCIIHexDecode", "AHx": data = Self.asciiHex(data)
            case "ASCII85Decode", "A85": data = Self.ascii85(data)
            case "DCTDecode", "DCT", "JPXDecode": return data
            default: return nil
            }
        }
        return data
    }

    func isJPEG(_ d: Dictionary) -> Bool {
        switch resolve(d["Filter"] ?? d["F"]) {
        case .name(let n): return n == "DCTDecode" || n == "DCT"
        case .array(let a): return a.contains { let n = resolve($0).name; return n == "DCTDecode" || n == "DCT" }
        default: return false
        }
    }

    // MARK: Pages

    struct Page { var dict: Dictionary; var resources: Dictionary; var box: [Double] }

    /// The first page and how many there are, walking the tree from the catalog. Resources and boxes inherit down it.
    func firstPage() -> (page: Page, count: Int)? {
        let catalog = objects.values.lazy.compactMap { o -> Dictionary? in
            if case .dict(let d) = o, d["Type"]?.name == "Catalog" { return d }
            return nil
        }.first
        guard let root = dict(catalog?["Pages"]) else { return nil }
        var total = 0
        var first: Page?
        func walk(_ node: Dictionary, resources: Dictionary?, box: [Double]?, depth: Int) {
            guard depth < 64 else { return }
            let own = dict(node["Resources"]) ?? resources
            let ownBox = boxArray(node["CropBox"]) ?? boxArray(node["MediaBox"]) ?? box
            if let kids = resolve(node["Kids"]).array {
                for kid in kids { if let d = dict(kid) { walk(d, resources: own, box: ownBox, depth: depth + 1) } }
            } else {
                total += 1
                if first == nil { first = Page(dict: node, resources: own ?? [:], box: ownBox ?? [0, 0, 612, 792]) }
            }
        }
        walk(root, resources: nil, box: nil, depth: 0)
        return first.map { ($0, total) }
    }

    private func boxArray(_ object: Object?) -> [Double]? {
        guard let a = resolve(object).array, a.count == 4 else { return nil }
        let v = a.compactMap { resolve($0).number }
        guard v.count == 4 else { return nil }
        return [min(v[0], v[2]), min(v[1], v[3]), max(v[0], v[2]), max(v[1], v[3])]
    }

    func contents(of page: Page) -> [UInt8] {
        switch resolve(page.dict["Contents"]) {
        case .array(let parts):
            return parts.reduce(into: [UInt8]()) { out, part in
                if let data = decoded(resolve(part)) { out += data; out.append(0x20) }
            }
        case let single:
            return decoded(single) ?? []
        }
    }

    // MARK: Bytes

    /// A number from the file as an Int, when it fits. A file can say anything, and `Int(_:)` traps on what doesn't.
    static func int(_ value: Double?) -> Int? {
        value.flatMap { Int(exactly: $0.rounded(.towardZero)) }
    }

    /// Where an inline image's end marker is: "EI" with white space before it, and white space or the end of the content after it. Its
    /// bytes can hold the same two letters, and what follows them would be read as drawing.
    static func inlineImageEnd(in content: [UInt8], from: Int) -> Int? {
        let space: Set<UInt8> = [0, 9, 10, 12, 13, 32]
        var at = from
        while let found = find(Array("EI".utf8), in: content, from: at, upTo: content.count) {
            let after = found + 2
            if found > 0, space.contains(content[found - 1]), after == content.count || space.contains(content[after]) { return found }
            at = found + 1
        }
        return nil
    }

    static func find(_ needle: [UInt8], in hay: [UInt8], from: Int, upTo: Int) -> Int? {
        guard !needle.isEmpty, upTo - from >= needle.count, from >= 0 else { return nil }
        var i = from
        let last = upTo - needle.count
        while i <= last {
            if hay[i] == needle[0] {
                var j = 1
                while j < needle.count, hay[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return nil
    }

    /// The object number in `12 0 obj`, reading back from the `obj` at `at`.
    private static func objectNumber(before at: Int, in b: [UInt8]) -> Int? {
        var i = at - 1
        func skipSpace() { while i >= 0, Lexer.isSpace(b[i]) { i -= 1 } }
        func digits() -> Int? {
            let end = i
            while i >= 0, b[i] >= 0x30, b[i] <= 0x39 { i -= 1 }
            guard i < end, end - i <= 10 else { return nil }
            return Int(String(decoding: b[(i + 1)...end], as: UTF8.self))
        }
        skipSpace()
        guard digits() != nil else { return nil }
        skipSpace()
        return digits()
    }

    private static func asciiHex(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [], high: UInt8?
        for c in data {
            if c == 0x3E { break }
            let v: UInt8
            switch c {
            case 0x30...0x39: v = c - 0x30
            case 0x41...0x46: v = c - 0x41 + 10
            case 0x61...0x66: v = c - 0x61 + 10
            default: continue
            }
            if let h = high { out.append(h << 4 | v); high = nil } else { high = v }
        }
        if let h = high { out.append(h << 4) }
        return out
    }

    private static func ascii85(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [], group: [UInt32] = []
        for c in data {
            if c == 0x7E { break }
            if c == 0x7A, group.isEmpty { out += [0, 0, 0, 0]; continue }
            guard c >= 0x21, c <= 0x75 else { continue }
            group.append(UInt32(c - 0x21))
            if group.count == 5 {
                let v = group.reduce(UInt32(0)) { $0 &* 85 &+ $1 }
                out += [UInt8(v >> 24), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)]
                group = []
            }
        }
        if group.count > 1 {
            let n = group.count
            let v = (group + [UInt32](repeating: 84, count: 5 - n)).reduce(UInt32(0)) { $0 &* 85 &+ $1 }
            out += [UInt8(v >> 24), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)].prefix(n - 1)
        }
        return out
    }

    private static func undoPredictor(_ data: [UInt8], predictor: Int, columns: Int, colors: Int, bits: Int) -> [UInt8]? {
        guard predictor >= 10 else { return predictor == 1 ? data : nil }   // TIFF predictor isn't used for vector content
        let pixel = max(1, colors * bits / 8), row = (colors * bits * columns + 7) / 8
        guard row > 0, pixel > 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        var previous = [UInt8](repeating: 0, count: row)
        var i = 0
        while i + 1 + row <= data.count {
            let type = data[i]
            var line = Array(data[(i + 1)..<(i + 1 + row)])
            for x in 0..<row {
                let a = x >= pixel ? Int(line[x - pixel]) : 0, b = Int(previous[x]), c = x >= pixel ? Int(previous[x - pixel]) : 0
                let add: Int
                switch type {
                case 1: add = a
                case 2: add = b
                case 3: add = (a + b) / 2
                case 4:
                    let p = a + b - c, pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                    add = pa <= pb && pa <= pc ? a : pb <= pc ? b : c
                default: add = 0
                }
                line[x] = UInt8(truncatingIfNeeded: Int(line[x]) + add)
            }
            out += line
            previous = line
            i += 1 + row
        }
        return out
    }

    // MARK: Lexer

    struct Lexer {
        let bytes: [UInt8]
        var position: Int

        static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C || c == 0x00 }
        static func isDelimiter(_ c: UInt8) -> Bool { [0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25].contains(c) }

        mutating func skip() {
            while position < bytes.count {
                let c = bytes[position]
                if Self.isSpace(c) { position += 1 }
                else if c == 0x25 { while position < bytes.count, bytes[position] != 0x0A, bytes[position] != 0x0D { position += 1 } }
                else { break }
            }
        }

        /// After a dictionary: where its stream's data starts, if `stream` follows.
        mutating func streamStart() -> Int? {
            skip()
            let word = Array("stream".utf8)
            guard position + word.count <= bytes.count, Array(bytes[position..<(position + word.count)]) == word else { return nil }
            var i = position + word.count
            if i < bytes.count, bytes[i] == 0x0D { i += 1 }
            if i < bytes.count, bytes[i] == 0x0A { i += 1 }
            return i
        }

        enum Token { case object(Object), keyword(String) }

        mutating func token() -> Token? {
            skip()
            guard position < bytes.count else { return nil }
            let c = bytes[position]
            switch c {
            case 0x2F: return .object(.name(name()))
            case 0x28: return .object(.string(literalString()))
            case 0x5B:
                position += 1
                var items: [Object] = []
                while true {
                    skip()
                    guard position < bytes.count else { break }
                    if bytes[position] == 0x5D { position += 1; break }
                    guard let item = object() else { position += 1; continue }
                    items.append(item)
                }
                return .object(.array(items))
            case 0x3C:
                if position + 1 < bytes.count, bytes[position + 1] == 0x3C { return .object(.dict(dictionary())) }
                return .object(.string(hexString()))
            case 0x3E, 0x5D, 0x7B, 0x7D, 0x29:
                position += 1
                return .keyword(String(UnicodeScalar(c)))
            default:
                let start = position
                while position < bytes.count, !Self.isSpace(bytes[position]), !Self.isDelimiter(bytes[position]) { position += 1 }
                let word = String(decoding: bytes[start..<position], as: UTF8.self)
                if let v = Double(word), word.first != "n", word.first != "i", word.first != "N", word.first != "I" { return .object(.number(v)) }
                switch word {
                case "true": return .object(.bool(true))
                case "false": return .object(.bool(false))
                case "null": return .object(.null)
                default: return .keyword(word)
                }
            }
        }

        /// One object, with `n g R` read as a reference.
        mutating func object() -> Object? {
            guard case .object(let o)? = token() else { return nil }
            if case .number(let n) = o, n >= 0, n == n.rounded() {
                let saved = position
                if case .object(.number(let g))? = token(), g == g.rounded(), case .keyword("R")? = token(), let id = PortablePDF.int(n) { return .reference(id) }
                position = saved
            }
            return o
        }

        private mutating func dictionary() -> Dictionary {
            position += 2
            var out: Dictionary = [:]
            while true {
                skip()
                guard position < bytes.count else { break }
                if bytes[position] == 0x3E {
                    position += position + 1 < bytes.count && bytes[position + 1] == 0x3E ? 2 : 1
                    break
                }
                guard bytes[position] == 0x2F else { position += 1; continue }
                let key = name()
                skip()
                if position < bytes.count, bytes[position] == 0x3E { continue }
                if let value = object() { out[key] = value }
            }
            return out
        }

        private mutating func name() -> String {
            position += 1
            var out: [UInt8] = []
            while position < bytes.count, !Self.isSpace(bytes[position]), !Self.isDelimiter(bytes[position]) {
                if bytes[position] == 0x23, position + 2 < bytes.count,
                   let v = UInt8(String(decoding: bytes[(position + 1)...(position + 2)], as: UTF8.self), radix: 16) {
                    out.append(v)
                    position += 3
                } else {
                    out.append(bytes[position])
                    position += 1
                }
            }
            return String(decoding: out, as: UTF8.self)
        }

        private mutating func literalString() -> [UInt8] {
            position += 1
            var depth = 1
            var out: [UInt8] = []
            while position < bytes.count {
                let c = bytes[position]
                position += 1
                if c == 0x5C { if position < bytes.count { out.append(bytes[position]); position += 1 }; continue }
                if c == 0x28 { depth += 1 }
                if c == 0x29 { depth -= 1; if depth == 0 { break } }
                out.append(c)
            }
            return out
        }

        private mutating func hexString() -> [UInt8] {
            position += 1
            let start = position
            while position < bytes.count, bytes[position] != 0x3E { position += 1 }
            let out = PortablePDF.asciiHexPublic(Array(bytes[start..<position]))
            position += 1
            return out
        }
    }

    fileprivate static func asciiHexPublic(_ data: [UInt8]) -> [UInt8] { asciiHex(data) }
}

/// RFC 1950 and 1951: zlib's stream format, for FlateDecode. No limit but memory; a PDF's stream lengths bound it in practice, and the
/// output stops at `maxOutput` so a hostile stream can't fill the machine.
enum Inflate {
    static let maxOutput = 1 << 30

    static func zlib(_ data: [UInt8]) -> [UInt8]? {
        guard data.count > 2, data[0] & 0x0F == 8, (Int(data[0]) << 8 | Int(data[1])) % 31 == 0 else { return nil }
        return raw(data, from: 2)
    }

    private struct Huffman {
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int]

        init?(lengths: ArraySlice<Int>) {
            symbols = [Int](repeating: 0, count: lengths.count)
            for l in lengths { counts[l] += 1 }
            if counts[0] == lengths.count { return nil }
            var offsets = [Int](repeating: 0, count: 16)
            for i in 1..<15 { offsets[i + 1] = offsets[i] + counts[i] }
            for (symbol, l) in lengths.enumerated() where l != 0 {
                symbols[offsets[l]] = symbol
                offsets[l] += 1
            }
            counts[0] = 0
        }
    }

    private static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    private static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    private static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    private static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    static func raw(_ input: [UInt8], from start: Int) -> [UInt8]? {
        var position = start, bitBuffer = 0, bitCount = 0
        var out: [UInt8] = []
        out.reserveCapacity(input.count * 3)

        func bits(_ need: Int) -> Int? {
            var value = bitBuffer
            while bitCount < need {
                guard position < input.count else { return nil }
                value |= Int(input[position]) << bitCount
                position += 1
                bitCount += 8
            }
            bitBuffer = value >> need
            bitCount -= need
            return value & ((1 << need) - 1)
        }
        func decode(_ h: Huffman) -> Int? {
            var code = 0, first = 0, index = 0
            for length in 1...15 {
                guard let bit = bits(1) else { return nil }
                code |= bit
                let count = h.counts[length]
                if code - count < first { return h.symbols[index + (code - first)] }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            return nil
        }
        func codes(_ lit: Huffman, _ dist: Huffman?) -> Bool {
            while true {
                guard let symbol = decode(lit) else { return false }
                if symbol < 256 {
                    out.append(UInt8(symbol))
                    if out.count > maxOutput { return false }
                } else if symbol == 256 {
                    return true
                } else {
                    let s = symbol - 257
                    guard s < 29, let extra = bits(lengthExtra[s]), let dist, let ds = decode(dist), ds < 30, let dextra = bits(distanceExtra[ds]) else { return false }
                    let length = lengthBase[s] + extra, distance = distanceBase[ds] + dextra
                    guard distance <= out.count, out.count + length <= maxOutput else { return false }
                    for _ in 0..<length { out.append(out[out.count - distance]) }
                }
            }
        }

        var last = 0
        repeat {
            guard let final = bits(1), let type = bits(2) else { return out.isEmpty ? nil : out }
            last = final
            switch type {
            case 0:
                bitBuffer = 0; bitCount = 0
                guard position + 4 <= input.count else { return nil }
                let n = Int(input[position]) | Int(input[position + 1]) << 8
                position += 4
                guard position + n <= input.count, out.count + n <= maxOutput else { return nil }
                out += input[position..<(position + n)]
                position += n
            case 1:
                var lengths = [Int](repeating: 8, count: 288)
                for i in 144..<256 { lengths[i] = 9 }
                for i in 256..<280 { lengths[i] = 7 }
                guard let lit = Huffman(lengths: lengths[...]), let dist = Huffman(lengths: [Int](repeating: 5, count: 30)[...]), codes(lit, dist) else { return nil }
            case 2:
                guard let hlit = bits(5), let hdist = bits(5), let hclen = bits(4) else { return nil }
                let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
                var lengths = [Int](repeating: 0, count: 320)
                for i in 0..<(hclen + 4) {
                    guard let v = bits(3) else { return nil }
                    lengths[order[i]] = v
                }
                guard let lengthCode = Huffman(lengths: lengths[0..<19]) else { return nil }
                lengths = [Int](repeating: 0, count: 320)
                let total = hlit + 257 + hdist + 1
                var i = 0
                while i < total {
                    guard let symbol = decode(lengthCode) else { return nil }
                    if symbol < 16 { lengths[i] = symbol; i += 1; continue }
                    var previous = 0, repeats = 0
                    switch symbol {
                    case 16:
                        guard i > 0, let r = bits(2) else { return nil }
                        previous = lengths[i - 1]; repeats = 3 + r
                    case 17:
                        guard let r = bits(3) else { return nil }
                        repeats = 3 + r
                    default:
                        guard let r = bits(7) else { return nil }
                        repeats = 11 + r
                    }
                    guard i + repeats <= total else { return nil }
                    for _ in 0..<repeats { lengths[i] = previous; i += 1 }
                }
                guard let lit = Huffman(lengths: lengths[0..<(hlit + 257)]) else { return nil }
                let dist = Huffman(lengths: lengths[(hlit + 257)..<total])
                guard codes(lit, dist) else { return nil }
            default:
                return nil
            }
        } while last == 0
        return out
    }
}

/// The content-stream interpreter: the same operators and rules as the Mac importer's `ScanState`.
struct PortablePDFImporter {
    private var pdf: PortablePDF
    private var ctm = Transform2D.identity
    private var stack: [Transform2D] = []
    private var paths: [Path] = []
    private var sub: Path?
    private var point = Vec2.zero
    private var shapes: [[Path]] = []
    private var textObjects = 0
    private var skippedImages = 0
    private var includeImages: Bool
    private var images: [(rect: Rect2, png: Data)] = []
    private var formDepth = 0

    static func importPage(from data: Data, targetUnits: LengthUnit, includeImages: Bool) throws -> (result: ImportResult, images: [ImportedImage]) {
        let pdf: PortablePDF
        do { pdf = try PortablePDF(data: data) } catch let e as PortablePDF.Failure { throw LoftLineIOError.malformed(e.message) }
        guard let (page, count) = pdf.firstPage() else { throw LoftLineIOError.malformed("PDF: no pages") }
        var run = PortablePDFImporter(pdf: pdf, includeImages: includeImages)
        let ptToUnit = LengthUnit.inch.convert(1.0 / 72, to: targetUnits)
        run.ctm = Transform2D.translation(Vec2(-page.box[0], -page.box[1])).concatenating(.scale(ptToUnit, ptToUnit))
        run.interpret(pdf.contents(of: page), resources: page.resources)

        let layer = Layer(name: "PDF Import", colorHex: SVGImporter.palette[0])
        let shapes = run.shapes.map { Shape(name: "Path", layerID: layer.id, paths: $0, origin: .imported(format: "pdf")) }
        var warnings: [String] = []
        if count > 1 { warnings.append("Only page 1 of \(count) was imported.") }
        if run.textObjects > 0 { warnings.append("\(run.textObjects) text object(s) were skipped; convert text to outlines first.") }
        if run.skippedImages > 0 { warnings.append("\(run.skippedImages) embedded image(s) were skipped.") }
        warnings += ImportGaps.warnings(shapes: shapes, layers: [layer], units: targetUnits)
        return (ImportResult(layers: shapes.isEmpty ? [] : [layer], shapes: shapes, warnings: warnings), run.images.map { ImportedImage(rect: $0.rect, png: $0.png) })
    }

    private init(pdf: PortablePDF, includeImages: Bool) {
        self.pdf = pdf
        self.includeImages = includeImages
    }

    private func map(_ x: Double, _ y: Double) -> Vec2 { Vec2(ctm.a * x + ctm.c * y + ctm.tx, ctm.b * x + ctm.d * y + ctm.ty) }

    private mutating func endSub() {
        if let s = sub, !s.segments.isEmpty { paths.append(s) }
        sub = nil
    }

    private mutating func moveTo(_ p: Vec2) { endSub(); sub = Path(start: p); point = p }

    private mutating func lineTo(_ p: Vec2) {
        if sub == nil { sub = Path(start: point) }
        sub?.segments.append(.line(to: p)); point = p
    }

    private mutating func curveTo(_ c1: Vec2, _ c2: Vec2, _ p: Vec2) {
        if sub == nil { sub = Path(start: point) }
        sub?.segments.append(.cubic(to: p, control1: c1, control2: c2)); point = p
    }

    private mutating func close() {
        guard var s = sub else { return }
        if let last = s.segments.last?.end, last.isApproximatelyEqual(to: s.start, tolerance: 1e-9), case .line = s.segments.last! { s.segments.removeLast() }
        if !s.segments.isEmpty { s.isClosed = true; paths.append(s) }
        sub = nil
        point = s.start
    }

    private mutating func paint(closing: Bool) {
        if closing { close() } else { endSub() }
        if !paths.isEmpty { shapes.append(paths) }
        paths = []
    }

    private mutating func interpret(_ content: [UInt8], resources: PortablePDF.Dictionary) {
        guard formDepth < 8 else { return }
        var lexer = PortablePDF.Lexer(bytes: content, position: 0)
        var operands: [PortablePDF.Object] = []
        func numbers(_ n: Int) -> [Double]? {
            guard operands.count >= n else { return nil }
            let v = operands.suffix(n).compactMap(\.number)
            return v.count == n ? v : nil
        }
        while let token = lexer.token() {
            switch token {
            case .object(let o):
                operands.append(o)
                if operands.count > 64 { operands.removeFirst() }
            case .keyword(let op):
                switch op {
                case "q": stack.append(ctm)
                case "Q": if let m = stack.popLast() { ctm = m }
                case "cm": if let n = numbers(6) { ctm = Transform2D(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5]).concatenating(ctm) }
                case "m": if let n = numbers(2) { moveTo(map(n[0], n[1])) }
                case "l": if let n = numbers(2) { lineTo(map(n[0], n[1])) }
                case "c": if let n = numbers(6) { curveTo(map(n[0], n[1]), map(n[2], n[3]), map(n[4], n[5])) }
                case "v": if let n = numbers(4) { curveTo(point, map(n[0], n[1]), map(n[2], n[3])) }
                case "y": if let n = numbers(4) { let p = map(n[2], n[3]); curveTo(map(n[0], n[1]), p, p) }
                case "h": close()
                case "re":
                    if let n = numbers(4) {
                        let (x, y, w, h) = (n[0], n[1], n[2], n[3])
                        moveTo(map(x, y)); lineTo(map(x + w, y)); lineTo(map(x + w, y + h)); lineTo(map(x, y + h))
                        close()
                    }
                // Only a plain stroke keeps an open subpath; every fill implicitly closes it.
                case "S": paint(closing: false)
                case "s", "f", "F", "f*", "b", "b*", "B", "B*": paint(closing: true)
                case "n": sub = nil; paths = []
                case "BT": textObjects += 1
                case "BI":
                    // An inline image: its data can hold anything, so it is skipped by its end marker.
                    if let end = PortablePDF.inlineImageEnd(in: content, from: lexer.position) { lexer.position = end + 2 }
                    skippedImages += 1
                case "Do":
                    if let name = operands.last?.name { place(name, resources: resources) }
                default: break
                }
                operands.removeAll(keepingCapacity: true)
            }
        }
    }

    private mutating func place(_ name: String, resources: PortablePDF.Dictionary) {
        guard let xobjects = pdf.dict(resources["XObject"]) else { return }
        let object = pdf.resolve(xobjects[name])
        guard case .stream(let d, _) = object else { return }
        switch pdf.resolve(d["Subtype"]).name {
        case "Form":
            let saved = ctm
            if let a = pdf.resolve(d["Matrix"]).array, a.count == 6 {
                let m = a.compactMap { pdf.resolve($0).number }
                if m.count == 6 { ctm = Transform2D(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]).concatenating(ctm) }
            }
            formDepth += 1
            interpret(pdf.decoded(object) ?? [], resources: pdf.dict(d["Resources"]) ?? resources)
            formDepth -= 1
            ctm = saved
        case "Image":
            guard includeImages, let png = imagePNG(object, d) else { skippedImages += 1; return }
            images.append((Rect2(points: [map(0, 0), map(1, 0), map(0, 1), map(1, 1)]), png))
        default: break
        }
    }

    private func imagePNG(_ object: PortablePDF.Object, _ d: PortablePDF.Dictionary) -> Data? {
        guard let data = pdf.decoded(object) else { return nil }
        if pdf.isJPEG(d) { return RasterCodec.png(fromEncoded: Data(data)) }
        guard let w = PortablePDF.int(pdf.resolve(d["Width"]).number), let h = PortablePDF.int(pdf.resolve(d["Height"]).number), w > 0, h > 0 else { return nil }
        guard (pdf.resolve(d["BitsPerComponent"]).number ?? 8) == 8 else { return nil }
        var components = 3
        switch pdf.resolve(d["ColorSpace"]).name {
        case "DeviceGray": components = 1
        case "DeviceCMYK": components = 4
        default: break
        }
        guard let needed = PDFImporter.imageByteCount(width: w, height: h, components: components), data.count >= needed else { return nil }
        return RasterCodec.png(width: w, height: h, samples: data, components: components)
    }
}
