import Foundation
import Testing
@testable import CodexBarCore

struct JSONNumberTests {
    @Test
    func `parsed JSON booleans remain distinct from numeric zero and one`() throws {
        let values = try #require(JSONSerialization.jsonObject(
            with: Data("[true,false,0,1,-1,0.0,1.0,1.5,\"true\",null]".utf8)) as? [Any])

        for (index, value) in values.enumerated() {
            let pluginValue = JSONProviderPluginValue(value)
            #expect(pluginValue.isBoolean == (index < 2))
            #expect(pluginValue.isNumber == (2..<8).contains(index))
        }
    }

    @Test
    func `boxed numeric types never become plugin booleans`() {
        let numbers: [NSNumber] = [
            NSNumber(value: Int8(0)), NSNumber(value: Int8(1)),
            NSNumber(value: UInt8(0)), NSNumber(value: UInt8(1)),
            NSNumber(value: Int(0)), NSNumber(value: Int(1)),
            NSNumber(value: Int64.min), NSNumber(value: UInt64.max),
            NSNumber(value: Float(0)), NSNumber(value: Float(1)),
            NSNumber(value: Double(0)), NSNumber(value: Double(1)),
            NSDecimalNumber(string: "0"), NSDecimalNumber(string: "1"),
        ]
        for number in numbers {
            let value = JSONProviderPluginValue(number)
            #expect(value.isNumber)
            #expect(!value.isBoolean)
        }
        for boolean in [false, true] {
            let value = JSONProviderPluginValue(NSNumber(value: boolean))
            #expect(value.isBoolean)
            #expect(!value.isNumber)
            #expect(value.boolValue() == boolean)
        }
    }
}
