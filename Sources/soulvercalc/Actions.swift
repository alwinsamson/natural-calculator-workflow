//==========================================================================
// PROJECT: Natural Calculator (Alfred workflow)
//
// FILE: Actions.swift
//
// AUTHOR: AS
//
// START DATE: 11/23/2026
//
// LAST UPDATE: 11/23/2026
//
//--------------------------------------------------------------------------
// OVERVIEW:
//   The "More actions" list: everything you can do with one calculation.
//   Alfred result rows can't catch ⌘K, so ⌃↩ on a result runs --stash,
//   which saves the selected calculation to a file and re-opens Alfred on
//   the actions Script Filter (via an External Trigger). That filter reads
//   the file and lists what can be done with the calculation. Each action
//   sets calc_action, which a Conditional in the workflow routes to the
//   copy, paste, search-bar or remove step.
//--------------------------------------------------------------------------
// FUNCTIONS:
//   pendingFile           -- Where the selected calculation is kept
//   stashFromEnvironment  -- Save the calc_* variables of the chosen row
//   actionsOutput         -- Script Filter JSON for the actions list
//==========================================================================

import Foundation


func pendingFile() -> URL
{
    dataDirectory().appendingPathComponent("pending_action.json")
}


/***************************************************************************
 * stashFromEnvironment -- Save the calc_* variables of the chosen row     *
 *                                                                         *
 *    The External Trigger that opens the actions list can't carry Alfred  *
 *    variables across, so the selected calculation goes through a file.   *
 *    It is overwritten on every ⌃↩, so there is never more than one.      *
 *                                                                         *
 * OUTPUT:  none; prints the reason to stderr if the file can't be written *
 *                                                                         *
 * HISTORY:                                                                *
 *   11/23/2026 AS : Created.                                              *
 *=========================================================================*/
func stashFromEnvironment()
{
    let env = ProcessInfo.processInfo.environment
    guard let query = env["calc_query"], let result = env["calc_result"] else
    {
        FileHandle.standardError.write(Data("--stash: no calc_query/calc_result\n".utf8))
        return
    }
    let entry = HistoryEntry(
        query: query,
        result: result,
        raw: env["calc_raw"] ?? result,
        kind: AnswerKind(rawValue: env["calc_kind"] ?? "") ?? .math,
        date: Date())

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    do
    {
        try FileManager.default.createDirectory(
            at: dataDirectory(), withIntermediateDirectories: true)
        try encoder.encode(entry).write(to: pendingFile(), options: .atomic)
    }
    catch
    {
        FileHandle.standardError.write(
            Data("Writing \(pendingFile().path) failed: \(error)\n".utf8))
    }
}


/***************************************************************************
 * actionsOutput -- Script Filter JSON for the actions list                *
 *                                                                         *
 *    The calculator's actions for one result. Typing filters the list by  *
 *    title. "Remove from History" only appears when the calculation is    *
 *    actually in history.                                                 *
 *                                                                         *
 * INPUT:   filter -- text typed after the actions keyword                 *
 *                                                                         *
 * OUTPUT:  {"items": [...]}; each item carries calc_action plus the       *
 *          calc_* variables so copy and paste still record to history     *
 *                                                                         *
 * HISTORY:                                                                *
 *   11/23/2026 AS : Created.                                              *
 *=========================================================================*/
func actionsOutput(_ filter: String) -> [String: Any]
{
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let data = try? Data(contentsOf: pendingFile()),
          let entry = try? decoder.decode(HistoryEntry.self, from: data)
    else
    {
        return ["items": [["title": "No calculation selected",
                           "subtitle": "Press ⌃↩ on a calculator result to see its actions",
                           "valid": false]]]
    }

    let both = "\(entry.query) = \(entry.result)"
    var actions: [(title: String, value: String, action: String)] = [
        ("Copy Answer", entry.result, "copy"),
        ("Paste Answer", entry.result, "paste"),
        ("Copy Unformatted Answer", entry.raw, "copy"),
        ("Copy Question", entry.query, "copy"),
        ("Copy Question and Answer", both, "copy"),
        // alfredSearchText adds the word keyword when the text starts with a
        // word ("monday in 3 weeks"), or Alfred wouldn't calculate it.
        ("Put Answer in Search Bar", alfredSearchText(entry.result), "search"),
        ("Put Question in Search Bar", alfredSearchText(entry.query), "search"),
    ]
    if loadHistory().contains(where: { $0.query == entry.query })
    {
        actions.append(("Remove from History", entry.query, "forget"))
    }

    let words = filter.lowercased().split(separator: " ").map(String.init)
    let items: [[String: Any]] = actions
        .filter { action in words.allSatisfy { action.title.lowercased().contains($0) } }
        .map
        {
            action in
            [
                "title": action.title,
                "subtitle": action.value,
                "arg": action.value,
                "icon": ["path": "icons/\(entry.kind.rawValue).png"],
                "variables": [
                    "calc_action": action.action,
                    "calc_query": entry.query,
                    "calc_result": entry.result,
                    "calc_raw": entry.raw,
                    "calc_kind": entry.kind.rawValue,
                ],
            ]
        }

    return ["items": items.isEmpty
                ? [["title": "No matching action", "valid": false]] : items,
            "skipknowledge": true]
}
