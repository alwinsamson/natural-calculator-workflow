//==========================================================================
// PROJECT: Natural Calculator (Alfred workflow)
//
// FILE: History.swift
//
// AUTHOR: AS
//
// START DATE: 11/23/2026
//
// LAST UPDATE: 11/23/2026
//
//--------------------------------------------------------------------------
// OVERVIEW:
//   Calculator history. A
//   calculation is saved when the user acts on it (copy, raw copy, paste),
//   not on every keystroke. The history keyword lists saved calculations,
//   filtered by what's typed, with a live answer on top when the text is
//   itself a calculation.
//--------------------------------------------------------------------------
// FUNCTIONS:
//   historyFile          -- Where history is stored
//   loadHistory          -- Read saved calculations, newest first
//   saveHistory          -- Write calculations back
//   recordFromEnvironment -- Save the calc_* variables Alfred passes on
//   forgetCalculation    -- Remove one calculation
//   relativeTime         -- "5 min ago" style label
//   historyOutput        -- Script Filter JSON for the history keyword
//==========================================================================

import Foundation


// Enough to scroll back a few weeks without the JSON file mattering for
// speed (it's read on every keystroke of the history keyword).
let HISTORY_LIMIT = 200
let HISTORY_ROWS_SHOWN = 50


struct HistoryEntry: Codable
{
    var query: String
    var result: String
    var raw: String
    var kind: AnswerKind
    var date: Date
}


func historyFile() -> URL
{
    dataDirectory().appendingPathComponent("history.json")
}


func loadHistory() -> [HistoryEntry]
{
    guard let data = try? Data(contentsOf: historyFile()) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
}


func saveHistory(_ entries: [HistoryEntry])
{
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    do
    {
        try FileManager.default.createDirectory(
            at: dataDirectory(), withIntermediateDirectories: true)
        try encoder.encode(entries).write(to: historyFile(), options: .atomic)
    }
    catch
    {
        FileHandle.standardError.write(
            Data("Writing \(historyFile().path) failed: \(error)\n".utf8))
    }
}


/***************************************************************************
 * recordFromEnvironment -- Save the calc_* variables Alfred passes on     *
 *                                                                         *
 *    answerItem puts calc_query, calc_result, calc_raw and calc_kind on   *
 *    each result row. Alfred hands them to the --record step as           *
 *    environment variables when the row is actioned. Re-running a         *
 *    calculation moves it to the top instead of duplicating it.           *
 *                                                                         *
 * OUTPUT:  none. Does nothing when history is turned off or the           *
 *          variables are missing.                                         *
 *                                                                         *
 * HISTORY:                                                                *
 *   11/23/2026 AS : Created.                                              *
 *=========================================================================*/
func recordFromEnvironment()
{
    guard Settings.current.saveHistory else { return }
    let env = ProcessInfo.processInfo.environment
    guard let query = env["calc_query"], !query.isEmpty,
          let result = env["calc_result"], !result.isEmpty
    else
    {
        return
    }

    let entry = HistoryEntry(
        query: query,
        result: result,
        raw: env["calc_raw"] ?? result,
        kind: AnswerKind(rawValue: env["calc_kind"] ?? "") ?? .math,
        date: Date())

    var entries = loadHistory().filter { $0.query != query }
    entries.insert(entry, at: 0)
    saveHistory(Array(entries.prefix(HISTORY_LIMIT)))
}


func forgetCalculation(_ query: String)
{
    saveHistory(loadHistory().filter { $0.query != query })
}


func relativeTime(_ date: Date) -> String
{
    if Date().timeIntervalSince(date) < 60 { return "just now" }
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
}


/***************************************************************************
 * historyOutput -- Script Filter JSON for the history keyword             *
 *                                                                         *
 *    One box that both calculates and searches. If the                    *
 *    text is a calculation its live answer comes first, then saved        *
 *    calculations whose query or result contain every typed word.         *
 *                                                                         *
 * INPUT:   filter -- text typed after the history keyword                 *
 *          rates  -- cached ECB rates or nil                              *
 *                                                                         *
 * OUTPUT:  {"items": [...]} with skipknowledge so Alfred keeps the order  *
 *          (newest first) instead of re-sorting by usage                  *
 *                                                                         *
 * HISTORY:                                                                *
 *   11/23/2026 AS : Created.                                              *
 *=========================================================================*/
func historyOutput(_ filter: String, rates: CachedRates?) -> [String: Any]
{
    let trimmed = filter.trimmingCharacters(in: .whitespaces)
    var items: [[String: Any]] = []

    if let answer = evaluate(trimmed, rates: rates)
    {
        let subtitle = [trimmed, answer.detail].compactMap { $0 }
            .joined(separator: "  ·  ")
        items.append(answerItem(query: trimmed, answer: answer,
                                title: answer.formatted, subtitle: subtitle,
                                icon: "icons/\(answer.kind.rawValue).png",
                                autocomplete: answer.formatted))
    }

    if !Settings.current.saveHistory
    {
        items.append(["title": "History is turned off",
                      "subtitle": "Turn on “Save history” in Configure Workflow",
                      "valid": false])
        return ["items": items, "skipknowledge": true]
    }

    let words = trimmed.lowercased().split(separator: " ").map(String.init)
    let matches = loadHistory().filter
    {
        entry in
        let haystack = "\(entry.query) \(entry.result)".lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }

    for entry in matches.prefix(HISTORY_ROWS_SHOWN)
    {
        let answer = Answer(formatted: entry.result, raw: entry.raw,
                            detail: nil, kind: entry.kind)
        // ⌃↩ opens the actions list (answerItem), which includes "Remove
        // from History" for entries like these.
        items.append(answerItem(query: entry.query, answer: answer,
                                title: entry.query,
                                subtitle: "\(entry.result)  ·  \(relativeTime(entry.date))",
                                icon: "icons/\(entry.kind.rawValue).png",
                                autocomplete: entry.query))
    }

    if items.isEmpty
    {
        let noHistory = loadHistory().isEmpty
        items.append([
            "title": noHistory ? "No calculations yet" : "No matching calculations",
            "subtitle": noHistory
                ? "Copy (↩) or paste (⌥↩) a result and it appears here"
                : "Try fewer words",
            "valid": false,
        ])
    }
    return ["items": items, "skipknowledge": true]
}
