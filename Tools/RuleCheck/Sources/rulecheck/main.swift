import Foundation
import os
import ScudoKit
import ScudoShared

// Usage:
//   swift run rulecheck update [--dir DIR] [--force]   download, convert, compile with WebKit
//   swift run rulecheck e2e    [--dir DIR]             blocking test in a WKWebView

let arguments = CommandLine.arguments.dropFirst()
let command = arguments.first ?? "update"

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.index(after: index) < arguments.endIndex else { return nil }
    return arguments[arguments.index(after: index)]
}

let directory = URL(fileURLWithPath: option("--dir") ?? FileManager.default.temporaryDirectory.appending(path: "scudo-rulecheck").path(percentEncoded: false))
let store = ScudoStore(root: directory)
print("Data directory: \(directory.path(percentEncoded: false))")

func megabytes(_ bytes: Int) -> String {
    String(format: "%.2f MB", Double(bytes) / 1_048_576)
}

@MainActor
func compileAll(_ webKit: WebKitRules) async -> Bool {
    var ok = true
    for kind in BlockerKind.allCases {
        do {
            let json = try String(contentsOf: store.rulesURL(for: kind), encoding: .utf8)
            try await webKit.compile(kind, json: json)
        } catch {
            ok = false
            print("✘ WebKit rejected \(kind.rawValue): \(error)")
        }
    }
    return ok
}

switch command {
case "update":
    let force = arguments.contains("--force")
    let webKit = try WebKitRules(directory: directory.appending(path: "WebKit"))
    let marks = OSAllocatedUnfairLock(initialState: [(Date, EngineProgress)]())
    // The "reload" step compiles each blocker with WebKit, like Safari does.
    let engine = ProtectionEngine(store: store, reloader: { kind in
        let json = try String(contentsOf: store.rulesURL(for: kind), encoding: .utf8)
        try await webKit.compile(kind, json: json)
        return .reloaded
    })

    let started = Date()
    let summary = await engine.update(forceDownload: force, forceRebuild: force) { progress in
        marks.withLock { $0.append((Date(), progress)) }
    }
    let elapsed = Date().timeIntervalSince(started)

    // Conversion time of a blocker = from its "converting" mark to the next mark.
    let timeline = marks.withLock { $0 }
    var conversionTimes: [BlockerKind: TimeInterval] = [:]
    for (index, (date, progress)) in timeline.enumerated() {
        if case .converting(let kind) = progress, index + 1 < timeline.count {
            conversionTimes[kind] = timeline[index + 1].0.timeIntervalSince(date)
        }
    }

    let state = store.loadState()
    print("\nSafari version: \(RuleConverter.safariVersion) · converter \(RuleConverter.converterVersion) · total \(String(format: "%.1f", elapsed)) s\n")
    for kind in BlockerKind.allCases {
        let record = state[blocker: kind]
        let lists = record.includedFilterIDs.map(String.init).joined(separator: ",")
        print("\(kind.title) [lists \(lists)]")
        print("  source rules \(record.sourceRuleCount) → Safari rules \(record.safariRuleCount)"
              + " · discarded \(record.discardedRuleCount) · unconvertible \(record.unconvertibleRuleCount)")
        print("  JSON \(megabytes(record.jsonByteCount))"
              + " · conversion \(String(format: "%.2f", conversionTimes[kind] ?? 0)) s"
              + " · WebKit compile \(String(format: "%.2f", webKit.timings[kind] ?? 0)) s"
              + (record.reloadError.map { " · ERROR \($0)" } ?? ""))
    }
    for (id, error) in summary.failedFilters.sorted(by: { $0.key < $1.key }) {
        print("✘ list \(id): \(error)")
    }
    if summary.rebuiltBlockers.isEmpty {
        // Nothing changed: still prove the existing files compile.
        print(await compileAll(webKit) ? "\n✔ Existing rules compile in WebKit" : "\n✘ WebKit compilation failed")
    } else {
        print(summary.hasErrors ? "\n✘ Completed with errors" : "\n✔ All blockers converted and accepted by WebKit")
    }
    exit(summary.hasErrors ? 1 : 0)

case "lists":
    // Size of every downloaded list converted on its own (helps choosing defaults).
    for list in FilterCatalog.all {
        guard let text = store.filterText(id: list.id) else {
            print("\(list.id) \(list.name): not downloaded")
            continue
        }
        let output = RuleConverter.convert(rules: RuleText.lines(of: text))
        print("\(list.id) \(list.name) [\(list.blocker.rawValue)\(list.enabledByDefault ? ", on" : "")]: "
              + "\(output.sourceRuleCount) → \(output.safariRuleCount) rules, \(megabytes(output.json.utf8.count))"
              + (output.discardedRuleCount > 0 ? ", discarded \(output.discardedRuleCount)" : ""))
    }

case "e2e":
    let passed = try await EndToEndTest(store: store, directory: directory).run()
    exit(passed ? 0 : 1)

default:
    print("Unknown command \(command). Use: update | e2e")
    exit(2)
}
