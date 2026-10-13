import Foundation
import ObjectiveC
import os

private let tripwireLog = Logger(subsystem: "com.macmaster.app", category: "tripwire")

/// Logs the call stack of any Objective-C exception raised off the main thread. AppKit raises one when
/// interface code runs on a background thread; system code often swallows it and the app freezes with
/// no crash report. The stack in the log (category "tripwire") names the caller. Never changes behavior.
enum ExceptionTripwire {
    private static var previous: objc_exception_preprocessor?

    static func install() {
        previous = objc_setExceptionPreprocessor { exception in
            if !Thread.isMainThread, let e = exception as? NSException {
                let stack = Thread.callStackSymbols.joined(separator: "\n")
                tripwireLog.fault("\(e.name.rawValue, privacy: .public): \(e.reason ?? "", privacy: .public)\n\(stack, privacy: .public)")
            }
            return ExceptionTripwire.previous.map { $0(exception) } ?? exception
        }
    }
}
