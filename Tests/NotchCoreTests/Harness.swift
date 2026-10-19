import Foundation

// Мінімальний набір для тестів: ця збірка Command Line Tools не має робочого XCTest/Swift Testing.
nonisolated(unsafe) private var failures: [String] = []
nonisolated(unsafe) private var currentTest = ""
nonisolated(unsafe) private var testCount = 0

func expect(_ condition: @autoclosure () throws -> Bool, _ note: String = "",
            file: StaticString = #fileID, line: UInt = #line) rethrows {
    if try !condition() {
        failures.append("✗ \(currentTest) — \(file):\(line) \(note)")
    }
}

func run(_ name: String, _ body: () throws -> Void) {
    currentTest = name
    testCount += 1
    let before = failures.count
    do { try body() } catch { failures.append("✗ \(name) — виняток: \(error)") }
    print(failures.count == before ? "  ✓ \(name)" : "  ✗ \(name)")
}

func finish() -> Never {
    if failures.isEmpty {
        print("\nУсі \(testCount) тестів пройдено.")
        exit(0)
    }
    print("\nПровалено:\n" + failures.joined(separator: "\n"))
    exit(1)
}
