/// A value that is worked out when a post or machine is used and never read from or written to a file: a post file or a
/// project's copy cannot carry it, so it cannot switch on what it controls. It decodes as nil whatever the file holds and
/// encodes nothing, so the type's JSON is byte-for-byte what it was before the field existed. It compares by value, so a
/// change to it still changes the profile it sits on (the export sheets re-post on that).
@propertyWrapper
public struct NeverCoded<Value: Hashable & Sendable>: Codable, Hashable, Sendable {
    public var wrappedValue: Value?
    public init(wrappedValue: Value?) { self.wrappedValue = wrappedValue }
    public init(from decoder: Decoder) throws { wrappedValue = nil }
    public func encode(to encoder: Encoder) throws {}
}

extension KeyedDecodingContainer {
    func decode<V>(_ type: NeverCoded<V>.Type, forKey key: Key) throws -> NeverCoded<V> {
        NeverCoded(wrappedValue: nil)
    }
}

extension KeyedEncodingContainer {
    mutating func encode<V>(_ value: NeverCoded<V>, forKey key: Key) throws {}
}
