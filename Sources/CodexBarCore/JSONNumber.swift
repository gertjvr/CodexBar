import Foundation

enum JSONNumber {
    /// JSONSerialization boxes booleans as Foundation's shared true/false objects.
    /// Value equality, Bool casts, and objCType also accept some numeric zero/one values.
    /// Identity preserves that distinction without requiring a CoreFoundation module on Windows.
    static func isBoolean(_ number: NSNumber) -> Bool {
        number === NSNumber(value: true) || number === NSNumber(value: false)
    }
}
