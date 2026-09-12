import Foundation

/// Fixed-width decoding shared by sensor polling and diagnostics. No heap
/// allocation, unaligned loads, or platform-endian assumptions.
enum SMCNumber {
    static func decode(type: String, bytes: UnsafeRawBufferPointer) -> Double? {
        switch type {
        case "sp78":
            guard bytes.count == 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "fpe2":
            guard bytes.count == 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "flt ":
            guard bytes.count == 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 |
                UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let number = Float(bitPattern: bits)
            return number.isFinite ? Double(number) : nil
        case "ui8 ", "ui16", "ui32", "ui64", "flag":
            let width = type == "ui64" ? 8 : type == "ui32" ? 4 : type == "ui16" ? 2 : 1
            guard bytes.count == width else { return nil }
            return Double(bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
        default:
            return nil
        }
    }
}
