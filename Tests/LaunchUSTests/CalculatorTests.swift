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
}
