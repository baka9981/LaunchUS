import Foundation
import Testing
@testable import LaunchUS

struct CalculatorTests {
    @Test func sumsFollowPrecedence() {
        #expect(Calculator.evaluate("2+3*4")?.copyText == "14")
        #expect(Calculator.evaluate("(2+3)×4")?.copyText == "20")
        #expect(Calculator.evaluate("2^10")?.copyText == "1024")
        #expect(Calculator.evaluate("0.1+0.2")?.copyText == "0.3")
        #expect(Calculator.evaluate("-3 * 2 =")?.copyText == "-6")
        #expect(Calculator.evaluate("1234*1000")?.display == "1,234,000")
    }

    @Test func plainNamesAreNotSums() {
        #expect(Calculator.evaluate("2048") == nil)
        #expect(Calculator.evaluate("1Password") == nil)
        #expect(Calculator.evaluate("Xcode") == nil)
        #expect(Calculator.evaluate("3+") == nil)
    }

    @Test func unitsConvert() {
        #expect(Calculator.evaluate("10 km to mi")?.copyText == "6.21371192237")
        #expect(Calculator.evaluate("100f to c").map { Double($0.copyText)! }.map { abs($0 - 37.7777777778) < 0.0001 } == true)
        #expect(Calculator.evaluate("1 kg 换成 斤")?.copyText == "2")
        #expect(Calculator.evaluate("2 km2 in m2")?.copyText == "2000000")
        #expect(Calculator.evaluate("10 kg to km") == nil)
    }
}
