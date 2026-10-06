//
//  ProtoFields.swift
//  OmniTAK Mobile
//
//  A protobuf message as a list of its top-level fields: read it, change some of
//  them, write it back. Every field that was not edited, including the ones this
//  app has never heard of, comes back byte for byte and in the order it came in.
//
//  Why this exists (#148): a Meshtastic radio does not merge the `set_config` or
//  `set_channel` it receives. It replaces the whole sub-config (or channel) with
//  it, so a message that carries only the one field the operator changed puts
//  every other field back to its default. The app therefore keeps the bytes the
//  radio sent during the config download and writes those back with one field
//  changed. Decoding them into a Swift model and encoding that model again would
//  drop whatever the model does not know about, which is exactly the loss being
//  fixed, so the bytes are edited as they are.
//
//  Reading rules:
//   - Wire types 0 (varint), 1 (fixed64), 2 (length-delimited) and 5 (fixed32)
//     are read. Groups (3, 4) and the unused 6 and 7 make the message malformed.
//   - A malformed message gives nil. That is a tag or varint that runs off the
//     end, a varint of more than ten bytes or more than 64 bits, a length that
//     is more than what is left, a field number of 0 or above 2^29 - 1.
//   - Lengths are compared as UInt64 before they become an Int, and nothing
//     indexes past the end, so no input can trap.
//
//  Edits:
//   - `.set` puts a new field in place of every field with its number. A field
//     that was not there goes before the first field with a higher number, which
//     keeps a message that was in order in order.
//   - `.remove` drops every field with the number. The scalar helpers use it for
//     the proto3 default (0, false, "", empty bytes): the firmware leaves a
//     default out, so the edited message does too.
//   - `.nested` edits the message held in a length-delimited field. The field
//     stays present afterwards even when the message in it ends up empty, because
//     a message field that is present and empty is not the same as one that is
//     absent.
//

import Foundation

enum ProtoFields {

    // MARK: - Fields

    /// One top-level field of a message, as it was on the wire.
    struct Field: Equatable {
        let number: Int
        /// 0 varint, 1 fixed64, 2 length-delimited, 5 fixed32.
        let wireType: Int
        /// The tag and the value exactly as written. A varint that was written
        /// with more bytes than it needs keeps them.
        let raw: Data
        /// The value without the tag. For a length-delimited field, the bytes
        /// after the length.
        let value: Data

        /// The value of a varint field. Nil for any other wire type.
        var varintValue: UInt64? {
            guard wireType == 0 else { return nil }
            return ProtoFields.readVarint([UInt8](value), at: 0)?.value
        }
    }

    /// The highest field number protobuf allows, 2^29 - 1.
    static let maxFieldNumber = 536_870_911

    // MARK: - Reading

    /// The top-level fields of `message` in the order they appear. Nil when any
    /// part of it is malformed. An empty message is valid and has no fields.
    static func parse(_ message: Data) -> [Field]? {
        let bytes = [UInt8](message)
        var fields: [Field] = []
        var index = 0
        while index < bytes.count {
            let start = index
            guard let tag = readVarint(bytes, at: index) else { return nil }
            index = tag.next
            let number = tag.value >> 3
            let wireType = Int(tag.value & 0x07)
            guard number >= 1, number <= UInt64(maxFieldNumber) else { return nil }

            let valueStart: Int
            switch wireType {
            case 0:
                guard let value = readVarint(bytes, at: index) else { return nil }
                valueStart = index
                index = value.next
            case 1:
                guard bytes.count - index >= 8 else { return nil }
                valueStart = index
                index += 8
            case 2:
                guard let length = readVarint(bytes, at: index),
                      length.value <= UInt64(bytes.count - length.next) else { return nil }
                valueStart = length.next
                index = length.next + Int(length.value)
            case 5:
                guard bytes.count - index >= 4 else { return nil }
                valueStart = index
                index += 4
            default:
                return nil
            }
            fields.append(Field(
                number: Int(number),
                wireType: wireType,
                raw: Data(bytes[start..<index]),
                value: Data(bytes[valueStart..<index])
            ))
        }
        return fields
    }

    /// The fields written one after another. `serialize(parse(m)!) == m` for
    /// any message `parse` accepts.
    static func serialize(_ fields: [Field]) -> Data {
        var out = Data()
        for field in fields { out.append(field.raw) }
        return out
    }

    /// The value of the last varint field with this number, which is the one a
    /// protobuf reader keeps when a field is written twice. Nil when there is
    /// none or the last one is not a varint.
    static func varint(_ number: Int, in fields: [Field]) -> UInt64? {
        guard let last = fields.last(where: { $0.number == number }) else { return nil }
        return last.varintValue
    }

    // MARK: - Writing fields

    static func varintField(_ number: Int, _ value: UInt64) -> Field {
        var encoded = [UInt8]()
        appendVarint(&encoded, value)
        return field(number, wireType: 0, value: encoded)
    }

    static func boolField(_ number: Int, _ value: Bool) -> Field {
        varintField(number, value ? 1 : 0)
    }

    static func bytesField(_ number: Int, _ value: Data) -> Field {
        messageField(number, value)
    }

    static func stringField(_ number: Int, _ value: String) -> Field {
        messageField(number, Data(value.utf8))
    }

    /// A length-delimited field: bytes, a string, or a sub-message.
    static func messageField(_ number: Int, _ body: Data) -> Field {
        var length = [UInt8]()
        appendVarint(&length, UInt64(body.count))
        return field(number, wireType: 2, lengthPrefix: length, value: [UInt8](body))
    }

    // MARK: - Editing

    enum Edit {
        /// Put this field in place of every field with its number.
        case set(Field)
        /// Drop every field with this number.
        case remove(Int)
        /// Apply `edits` to the message in this field.
        case nested(Int, [Edit])

        /// A varint field. 0 is the proto3 default and removes the field.
        static func varint(_ number: Int, _ value: UInt64) -> Edit {
            value == 0 ? .remove(number) : .set(ProtoFields.varintField(number, value))
        }

        /// A bool field. false is the proto3 default and removes the field.
        static func bool(_ number: Int, _ value: Bool) -> Edit {
            value ? .set(ProtoFields.boolField(number, true)) : .remove(number)
        }

        /// A string field. "" is the proto3 default and removes the field.
        static func string(_ number: Int, _ value: String) -> Edit {
            value.isEmpty ? .remove(number) : .set(ProtoFields.stringField(number, value))
        }

        /// A bytes field. Empty is the proto3 default and removes the field.
        static func bytes(_ number: Int, _ value: Data) -> Edit {
            value.isEmpty ? .remove(number) : .set(ProtoFields.bytesField(number, value))
        }
    }

    /// `message` with `edits` applied in order. Nil when `message` is malformed,
    /// or when a nested edit meets a field that is not a message.
    static func patch(_ message: Data, _ edits: [Edit]) -> Data? {
        guard var fields = parse(message) else { return nil }
        for edit in edits {
            guard apply(edit, to: &fields) else { return nil }
        }
        return serialize(fields)
    }

    private static func apply(_ edit: Edit, to fields: inout [Field]) -> Bool {
        switch edit {
        case .set(let field):
            place(field, in: &fields)
            return true

        case .remove(let number):
            fields.removeAll { $0.number == number }
            return true

        case .nested(let number, let edits):
            let existing = fields.filter { $0.number == number }
            guard existing.allSatisfy({ $0.wireType == 2 }) else { return false }
            // A message field that appears more than once is one message: a
            // reader merges the copies, which for the bytes means joining them.
            var body = Data()
            for copy in existing { body.append(copy.value) }
            guard let patched = patch(body, edits) else { return false }
            place(messageField(number, patched), in: &fields)
            return true
        }
    }

    /// `field` takes the place of the first field with its number and the other
    /// fields with that number are dropped. With none, it goes before the first
    /// field with a higher number, or last.
    private static func place(_ field: Field, in fields: inout [Field]) {
        var placed = false
        fields = fields.compactMap { existing in
            guard existing.number == field.number else { return existing }
            if placed { return nil }
            placed = true
            return field
        }
        if !placed {
            let at = fields.firstIndex { $0.number > field.number } ?? fields.endIndex
            fields.insert(field, at: at)
        }
    }

    // MARK: - Wire helpers

    private static func tagValue(_ number: Int, wireType: Int) -> UInt64 {
        UInt64(truncatingIfNeeded: number) << 3 | UInt64(wireType)
    }

    private static func field(_ number: Int, wireType: Int, lengthPrefix: [UInt8] = [], value: [UInt8]) -> Field {
        var raw = [UInt8]()
        appendVarint(&raw, tagValue(number, wireType: wireType))
        raw.append(contentsOf: lengthPrefix)
        raw.append(contentsOf: value)
        return Field(number: number, wireType: wireType, raw: Data(raw), value: Data(value))
    }

    private static func appendVarint(_ out: inout [UInt8], _ value: UInt64) {
        var v = value
        while v > 0x7F {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
    }

    /// A varint at `index` and the index after it. Nil when it runs off the end
    /// of the buffer, is longer than ten bytes, or does not fit in 64 bits.
    private static func readVarint(_ bytes: [UInt8], at index: Int) -> (value: UInt64, next: Int)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var cursor = index
        while cursor < bytes.count, shift <= 63 {
            let byte = bytes[cursor]
            cursor += 1
            // The tenth byte only has room for bit 63.
            if shift == 63 && byte > 1 { return nil }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return (result, cursor) }
            shift += 7
        }
        return nil
    }
}
