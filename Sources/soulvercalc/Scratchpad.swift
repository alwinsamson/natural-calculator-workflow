//==========================================================================
// PROJECT: Natural Calculator (Alfred workflow)
//
// FILE: Scratchpad.swift
//
// AUTHOR: AS
//
// START DATE: 11/23/2026
//
// LAST UPDATE: 11/23/2026
//
//--------------------------------------------------------------------------
// OVERVIEW:
//   Multi-line scratchpad for the calc.alfredui panel. Every line of
//   the editor is calculated with SoulverCore's LineCollection, so later
//   lines can use earlier variables ("rent = $1,450" then "rent * 12").
//   The panel shows one result per line and a running total.
//--------------------------------------------------------------------------
// FUNCTIONS:
//   scratchpadOutput -- Alfred UI update JSON for the scratchpad text
//==========================================================================

import Foundation
import SoulverCore


/***************************************************************************
 * scratchpadOutput -- Alfred UI update JSON for the scratchpad text       *
 *                                                                         *
 *    Results are one per line, in the same order as the editor, so the    *
 *    two text areas line up as long as neither wraps a line. The text is  *
 *    also returned as the pad_text variable, which the panel persists,    *
 *    so the scratchpad survives closing the window.                       *
 *                                                                         *
 * INPUT:   text   -- whole editor contents, lines separated by \n         *
 *          adding -- text to append below it, from the "Add to Calculator *
 *                    Scratchpad" Universal Action; empty for normal edits *
 *          rates  -- cached ECB rates or nil                              *
 *                                                                         *
 * OUTPUT:  JSON action object with "update" and "variables". When adding, *
 *          it also replaces the editor text and moves the caret to the    *
 *          end so the new lines are in view.                              *
 *                                                                         *
 * WARNINGS:   Alfred UI text areas have no wrapping or alignment options, *
 *             so a line long enough to wrap pushes the results below it   *
 *             out of line.                                                *
 *                                                                         *
 * HISTORY:                                                                *
 *   11/23/2026 AS : Created.                                              *
 *   11/23/2026 AS : Added "adding" for the Universal Action.              *
 *=========================================================================*/
func scratchpadOutput(_ editorText: String, adding: String,
                      rates: CachedRates?) -> [String: Any]
{
    // Appended, never replaced, so an existing pad isn't lost. A blank line
    // keeps the added text visually separate. Windows line endings from
    // copied text would otherwise leave a stray \r on every line.
    let added = adding
        .replacingOccurrences(of: "\r\n", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let existing = editorText.trimmingCharacters(in: .newlines)
    let text = added.isEmpty ? editorText
        : existing.isEmpty ? added
        : "\(existing)\n\n\(added)"

    var customization = makeCustomization(provider: CachedECBRateProvider(rates))
    // Off in .standard, and the whole point of a multi-line pad.
    customization.featureFlags.variableDeclarations = true
    let lines = LineCollection(customization: customization)
    lines.setLinesWithExpressions(
        text.components(separatedBy: "\n").map(normaliseTemperatures))
    // Applied after the lines exist; setting it first had no effect.
    lines.setFormatting(formattingPreferences: displayPreferences())
    lines.evaluateAll()

    let results = lines.lines.map { $0.formattedResult }
    // quickSum comes back unformatted ("176.6666666667 °C"), so run it
    // through the same formatting as the lines.
    let formatter = EvaluationResultFormatter(customization: customization,
                                              formattingPreferences: displayPreferences())
    let total = lines.quickSum
        .map { formatter.format(result: $0.evaluationResult).stringValue } ?? ""

    // For the ⌘K menu's copy actions: results alone, and each line with
    // its result ("monthly * 12 → $26,760.00"), blank lines kept. An arrow,
    // not "=", so "rent = $1,450" doesn't become "rent = $1,450 = $1,450.00".
    let resultsText = results.joined(separator: "\n")
    let linesText = zip(lines.lines, results).map
    {
        line, result in
        result.isEmpty ? line.expression : "\(line.expression) → \(result)"
    }.joined(separator: "\n")

    var ids: [String: Any] = [
        "padResults": ["text": resultsText],
        "padTotal": ["text": total.isEmpty ? "—" : total],
    ]
    var output: [String: Any] = [
        "variables": [
            "pad_text": text,
            "pad_total": total,
            "pad_results": resultsText,
            "pad_lines": linesText,
        ],
    ]
    if !added.isEmpty
    {
        ids["padEditor"] = ["text": text]
        output["functions"] = ["ids": ["padEditor": "caretend"]]
    }
    output["update"] = ["relayout": true, "ids": ids]
    return output
}
