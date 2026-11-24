//==========================================================================
// PROJECT: Natural Calculator (Alfred workflow)
//
// FILE: main.swift
//
// AUTHOR: AS
//
// START DATE: 11/21/2026
//
// LAST UPDATE: 11/21/2026
//
//--------------------------------------------------------------------------
// OVERVIEW:
//   Command-line front end to SoulverCore for an Alfred workflow. It
//   evaluates natural-language maths ("10 usd in eur", "5pm london in
//   tokyo") and prints either Alfred Script Filter JSON or Alfred UI
//   update JSON. Currency rates come from the European Central Bank,
//   cached on disk and refreshed in a detached background run so typing
//   never waits on the network.
//--------------------------------------------------------------------------
// FUNCTIONS:
//   dataDirectory        -- Where the rate cache lives
//   loadCachedRates      -- Read cached ECB rates, nil if missing
//   refreshRates         -- Fetch ECB rates and write the cache
//   refreshIfStale       -- Start a background refresh when rates are old
//   makeCustomization    -- Engine settings wired to the cached rates
//   displayPreferences   -- Formatting from the user's settings
//   normaliseTemperatures -- "350 f in c" -> "350 °F in °C"
//   gmtLabel             -- "GMT+9" style label for a time zone
//   hasClockTime         -- Whether a date result carries a clock time
//   longDate             -- "Monday, December 14" for date-only results
//   relativeDays         -- "in 23 days" style distance from today
//   weekdayInSpan        -- Date for "<weekday> in N weeks" and similar
//   dateDetail           -- Weekday, GMT offset and gap to local time
//   currencyDetail       -- Which rate source a conversion used
//   evaluate             -- Calculate formatted and unformatted results
//   printJSON            -- Serialise a dictionary to stdout
//   answerItem           -- One Alfred result row for an answer
//   scriptFilterOutput   -- Alfred Script Filter JSON for a query
//   alfredSearchText     -- What the "Calculate" Universal Action types
//
//   History.swift, Actions.swift and Scratchpad.swift hold the history
//   list, the "More actions" list and the scratchpad panel.
//==========================================================================

import Foundation
import SoulverCore


//--------------------------------------------------------------------------
// Settings
//--------------------------------------------------------------------------

let BUNDLE_ID = "com.alwinsamson.calculator"
let ECB_URL = URL(
    string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!
// Alfred runs the Script Filter on every keystroke. This stops each
// keystroke from starting its own refresh while one is already running.
let REFRESH_RETRY_S: TimeInterval = 5 * 60


// User settings from Alfred's "Configure Workflow" panel, passed as
// environment variables (checkboxes arrive as "1" / "0"). Defaults match
// the ones in build.sh, so manual runs and the Alfred UI panel, which may
// not receive these variables, behave the same as a fresh install.
struct Settings
{
    let decimalPlaces: Int
    let thousandsSeparator: Bool
    let ratesMaxAge: TimeInterval
    let calculateWithoutKeyword: Bool
    let saveHistory: Bool

    static let current: Settings =
    {
        let env = ProcessInfo.processInfo.environment
        let places = Int(env["decimal_places"] ?? "") ?? 2
        // ECB publishes once per working day, so 6 hours keeps us within a
        // day of the source without hammering it.
        let hours = Double(env["rates_refresh_hours"] ?? "") ?? 6
        return Settings(
            decimalPlaces: min(max(places, 0), 10),
            thousandsSeparator: env["thousands_separator"] != "0",
            ratesMaxAge: max(hours, 1) * 3600,
            calculateWithoutKeyword: env["calculate_without_keyword"] != "0",
            saveHistory: env["save_history"] != "0")
    }()
}

// Common short city names that SoulverCore doesn't know by default.
let PLACE_ALIASES: [(name: String, aliases: [String], zone: String)] = [
    ("London", ["ldn"], "Europe/London"),
    ("San Francisco", ["sf"], "America/Los_Angeles"),
    ("Los Angeles", ["la"], "America/Los_Angeles"),
    ("New York", ["nyc", "ny"], "America/New_York"),
    ("Hong Kong", ["hk"], "Asia/Hong_Kong"),
    ("Singapore", ["sg"], "Asia/Singapore"),
]


//--------------------------------------------------------------------------
// Currency rates
//--------------------------------------------------------------------------

struct CachedRates: Codable
{
    // ECB rates are "units of currency per 1 EUR", stored as strings so
    // Decimal precision survives the JSON round trip.
    var perEuro: [String: String]
    var date: String
    var fetched: Date
}


/***************************************************************************
 * dataDirectory -- Where the rate cache lives                             *
 *                                                                         *
 *    Alfred passes alfred_workflow_data to Script Filters. Alfred UI      *
 *    scripts and manual test runs may not have it, so this falls back to  *
 *    the same path Alfred would use for this bundle id. That keeps one    *
 *    cache for every entry point.                                         *
 *                                                                         *
 * OUTPUT:  Directory URL. Not created here.                               *
 *                                                                         *
 * HISTORY:                                                                *
 *   11/21/2026 AS : Created.                                              *
 *=========================================================================*/
func dataDirectory() -> URL
{
    if let path = ProcessInfo.processInfo.environment["alfred_workflow_data"],
       !path.isEmpty
    {
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(
            "Library/Application Support/Alfred/Workflow Data/\(BUNDLE_ID)",
            isDirectory: true)
}


func ratesFile() -> URL
{
    dataDirectory().appendingPathComponent("ecb_rates.json")
}


func attemptMarker() -> URL
{
    dataDirectory().appendingPathComponent("ecb_rates.attempt")
}


func loadCachedRates() -> CachedRates?
{
    guard let data = try? Data(contentsOf: ratesFile()) else { return nil }
    return try? JSONDecoder().decode(CachedRates.self, from: data)
}


/***************************************************************************
 * refreshRates -- Fetch ECB rates and write the cache                     *
 *                                                                         *
 *    Parses the ECB daily XML with a regex instead of XMLParser because   *
 *    the format is two attributes per line and has been stable for years. *
 *                                                                         *
 * OUTPUT:  true on success. On failure prints the reason to stderr and    *
 *          leaves any existing cache untouched.                           *
 *                                                                         *
 * HISTORY:                                                                *
 *   11/21/2026 AS : Created.                                              *
 *=========================================================================*/
func refreshRates() async -> Bool
{
    let xml: String
    do
    {
        let (data, _) = try await URLSession.shared.data(from: ECB_URL)
        xml = String(decoding: data, as: UTF8.self)
    }
    catch
    {
        FileHandle.standardError.write(
            Data("ECB fetch failed: \(error.localizedDescription)\n".utf8))
        return false
    }

    var perEuro: [String: String] = ["EUR": "1"]
    let ratePattern = /currency='([A-Z]{3})'\s+rate='([0-9.]+)'/
    for match in xml.matches(of: ratePattern)
    {
        perEuro[String(match.1)] = String(match.2)
    }
    let date = xml.firstMatch(of: /time='([0-9-]+)'/).map { String($0.1) }

    guard perEuro["USD"] != nil, let date else
    {
        FileHandle.standardError.write(
            Data("ECB response had no USD rate or date. Format changed?\n".utf8))
        return false
    }

    let cache = CachedRates(perEuro: perEuro, date: date, fetched: Date())
    do
    {
        try FileManager.default.createDirectory(
            at: dataDirectory(), withIntermediateDirectories: true)
        try JSONEncoder().encode(cache).write(to: ratesFile(), options: .atomic)
    }
    catch
    {
        FileHandle.standardError.write(
            Data("Writing \(ratesFile().path) failed: \(error)\n".utf8))
        return false
    }
    return true
}


/***************************************************************************
 * refreshIfStale -- Start a background refresh when rates are old         *
 *                                                                         *
 *    Relaunches this binary with --refresh-rates and does not wait for    *
 *    it. The child's stdout must not be Alfred's pipe, otherwise Alfred   *
 *    would wait for the network before showing the result.                *
 *                                                                         *
 * INPUT:   rates -- current cache, nil if there is none                   *
 *                                                                         *
 * WARNINGS:   The attempt marker is touched before launching, so a        *
 *             failing network only retries every REFRESH_RETRY_S.         *
 *                                                                         *
 * HISTORY:                                                                *
 *   11/21/2026 AS : Created.                                              *
 *=========================================================================*/
func refreshIfStale(_ rates: CachedRates?)
{
    if let rates,
       Date().timeIntervalSince(rates.fetched) < Settings.current.ratesMaxAge
    {
        return
    }

    let manager = FileManager.default
    let marker = attemptMarker()
    if let attributes = try? manager.attributesOfItem(atPath: marker.path),
       let modified = attributes[.modificationDate] as? Date,
       Date().timeIntervalSince(modified) < REFRESH_RETRY_S
    {
        return
    }

    try? manager.createDirectory(
        at: dataDirectory(), withIntermediateDirectories: true)
    manager.createFile(atPath: marker.path, contents: nil)

    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        .resolvingSymlinksInPath()
    child.arguments = ["--refresh-rates"]
    child.standardOutput = FileHandle.nullDevice
    child.standardError = FileHandle.nullDevice
    try? child.run()
}


// SoulverCore asks for "units of X per 1 USD" (request.baseCurrencyCode is
// always USD in testing). Returning nil makes it fall back to its own
// built-in rates, which covers crypto and anything ECB doesn't publish.
// It also records which codes it answered and which it passed on, so the
// subtitle can say where a conversion's rate actually came from.
final class CachedECBRateProvider: CurrencyRateProvider
{
    let perEuro: [String: Decimal]
    private(set) var answeredCodes: Set<String> = []
    private(set) var fallbackCodes: Set<String> = []

    init(_ rates: CachedRates?)
    {
        var parsed: [String: Decimal] = [:]
        for (code, value) in rates?.perEuro ?? [:]
        {
            if let decimal = Decimal(string: value) { parsed[code] = decimal }
        }
        perEuro = parsed
    }

    func rateFor(request: CurrencyRateRequest) -> Decimal?
    {
        guard let target = perEuro[request.currencyCode],
              let base = perEuro[request.baseCurrencyCode],
              base != 0
        else
        {
            fallbackCodes.insert(request.currencyCode)
            return nil
        }
        answeredCodes.insert(request.currencyCode)
        return target / base
    }
}


//--------------------------------------------------------------------------
// Calculation
//--------------------------------------------------------------------------

// Shared by the single-line Calculator and the scratchpad's LineCollection
// so both read rates, places and formatting the same way.
func makeCustomization(provider: CachedECBRateProvider) -> EngineCustomization
{
    var customization = EngineCustomization.standard
    customization.currencyRateProvider = provider
    customization.featureFlags.useDefaultRatesForUnhandledCurrencies = true
    customization.customPlaces = PLACE_ALIASES.compactMap
    {
        guard let zone = TimeZone(identifier: $0.zone) else { return nil }
        return Place(name: $0.name, aliases: $0.aliases, timeZone: zone)
    }
    return customization
}


func displayPreferences() -> FormattingPreferences
{
    var preferences = FormattingPreferences()
    preferences.dp = Settings.current.decimalPlaces
    preferences.thousandsSeparatorDisabled = !Settings.current.thousandsSeparator
    return preferences
}


// Picks the history icon: calculator, arrows or clock.
enum AnswerKind: String, Codable
{
    case math
    case conversion
    case time
}


struct Answer
{
    let formatted: String
    let raw: String
    // Extra context for the subtitle, e.g. the weekday and GMT offset for a
    // time, or where a currency rate came from.
    let detail: String?
    let kind: AnswerKind
}


// SoulverCore reads lowercase "c" and "f" as other units (centi-, femto-),
// so "350 f in c" came back as 350. Uppercasing them only when both sides
// of a conversion are a bare f or c keeps "5 c" (cents, etc.) untouched.
func normaliseTemperatures(_ query: String) -> String
{
    let pattern = /(?i)(\d)\s*([fc])\s+(in|to|as|into)\s+([fc])\b/
    return query.replacing(pattern)
    {
        match in
        "\(match.1) °\(match.2.uppercased()) \(match.3) °\(match.4.uppercased())"
    }
}


/***************************************************************************
 * gmtLabel -- "GMT+9", "GMT-8", "GMT+5:30" or "GMT" for a time zone       *
 *                                                                         *
 * INPUT:   zone -- time zone to describe                                  *
 *          date -- moment to describe it at (daylight saving matters)     *
 *                                                                         *
 * OUTPUT:  Label string                                                   *
 *                                                                         *
 * HISTORY:                                                                *
 *   11/21/2026 AS : Created.                                              *
 *=========================================================================*/
func gmtLabel(_ zone: TimeZone, at date: Date) -> String
{
    let seconds = zone.secondsFromGMT(for: date)
    if seconds == 0 { return "GMT" }
    let sign = seconds < 0 ? "-" : "+"
    let hours = abs(seconds) / 3600
    let minutes = (abs(seconds) % 3600) / 60
    return minutes == 0
        ? "GMT\(sign)\(hours)"
        : "GMT\(sign)\(hours):\(String(format: "%02d", minutes))"
}


// DatestampType has no "has a clock time" flag, but every type that carries
// one is named after it (clockTime, nowInTimezone, weekdayWithClockTime...).
func hasClockTime(_ datestamp: Datestamp) -> Bool
{
    let typeName = String(describing: datestamp.type).lowercased()
    return typeName.contains("time") || typeName == "now"
}


// Date-only results read as "Monday, December 14", with the
// year only when it isn't this year.
func longDate(_ date: Date, zone: TimeZone = .current) -> String
{
    var calendar = Calendar.current
    calendar.timeZone = zone
    let sameYear = calendar.component(.year, from: date)
        == calendar.component(.year, from: Date())
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US")
    formatter.timeZone = zone
    formatter.dateFormat = sameYear ? "EEEE, MMMM d" : "EEEE, MMMM d, yyyy"
    return formatter.string(from: date)
}


// "today", "tomorrow", "in 23 days", "3 days ago" for the subtitle.
func relativeDays(_ date: Date) -> String
{
    let calendar = Calendar.current
    let days = calendar.dateComponents(
        [.day],
        from: calendar.startOfDay(for: Date()),
        to: calendar.startOfDay(for: date)).day ?? 0
    switch days
    {
    case 0: return "today"
    case 1: return "tomorrow"
    case -1: return "yesterday"
    case let n where n > 0: return "in \(n) days"
    default: return "\(-days) days ago"
    }
}


/***************************************************************************
 * weekdayInSpan -- Date for "<weekday> in N weeks" and similar            *
 *                                                                         *
 *    Returns the first matching weekday on or after the date N days,      *
 *    weeks, months or years from today: "monday in 3 weeks" asked on      *
 *    Saturday November 21 gives Monday December 14.                       *
 *                                                                         *
 *    SoulverCore instead returns the Monday inside the week 3 weeks       *
 *    from now (December 7), and no SoulverCore option changes that.       *
 *    This function handles only that phrase; every other query goes to    *
 *    SoulverCore.                                                         *
 *                                                                         *
 * INPUT:   query -- trimmed query, e.g. "fri in 2 weeks"                  *
 *                                                                         *
 * OUTPUT:  The date, or nil when the query isn't this phrase              *
 *                                                                         *
 * HISTORY:                                                                *
 *   11/21/2026 AS : Created.                                              *
 *=========================================================================*/
func weekdayInSpan(_ query: String) -> Date?
{
    let pattern = /(?i)^(sun|mon|tue|wed|thu|fri|sat)[a-z]*\s+in\s+(\d+)\s+(day|week|month|year)s?$/
    guard let match = query.firstMatch(of: pattern),
          let amount = Int(match.2)
    else
    {
        return nil
    }

    // Calendar weekdays run 1 (Sunday) to 7 (Saturday).
    let prefixes = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
    guard let index = prefixes.firstIndex(of: match.1.lowercased()) else
    {
        return nil
    }
    let units: [String: Calendar.Component] =
        ["day": .day, "week": .weekOfYear, "month": .month, "year": .year]
    guard let unit = units[match.3.lowercased()] else { return nil }

    let calendar = Calendar.current
    guard let base = calendar.date(byAdding: unit, value: amount,
                                   to: calendar.startOfDay(for: Date()))
    else
    {
        return nil
    }
    // nextDate(after:) is strictly after, so step back a second to make
    // "on or after" include the base day itself.
    return calendar.nextDate(after: base.addingTimeInterval(-1),
                             matching: DateComponents(weekday: index + 1),
                             matchingPolicy: .nextTime)
}


/***************************************************************************
 * dateDetail -- Weekday, GMT offset and gap to local time for a date      *
 *                                                                         *
 *    Date-only results get the weekday ("Monday, December 7"). Results    *
 *    with a clock time also get the zone's GMT offset and how far ahead   *
 *    or behind it is, e.g. "Sunday, November 22 · GMT+9 · 15h ahead".     *
 *                                                                         *
 * INPUT:   datestamp -- SoulverCore's date result                         *
 *                                                                         *
 * OUTPUT:  Detail string                                                  *
 *                                                                         *
 * WARNINGS:   SoulverCore only sets a time zone on "time in <place>"      *
 *             style results. Conversions like "5pm ldn in sf" come back   *
 *             without one, so they only get the weekday.                  *
 *                                                                         *
 * HISTORY:                                                                *
 *   11/21/2026 AS : Created.                                              *
 *=========================================================================*/
func dateDetail(_ datestamp: Datestamp) -> String
{
    let zone = datestamp.timezone ?? .current
    let date = datestamp.date
    let dayFormatter = DateFormatter()
    dayFormatter.locale = Locale(identifier: "en_US")
    dayFormatter.timeZone = zone
    dayFormatter.dateFormat = "EEEE, MMMM d"
    var parts = [dayFormatter.string(from: date)]

    if hasClockTime(datestamp), let explicitZone = datestamp.timezone
    {
        parts.append(gmtLabel(explicitZone, at: date))
        let gap = explicitZone.secondsFromGMT(for: date)
            - TimeZone.current.secondsFromGMT(for: date)
        if gap != 0
        {
            let hours = Double(abs(gap)) / 3600
            let amount = hours == hours.rounded()
                ? String(Int(hours)) : String(format: "%.1f", hours)
            parts.append("\(amount)h \(gap > 0 ? "ahead" : "behind")")
        }
    }
    return parts.joined(separator: " · ")
}


/***************************************************************************
 * currencyDetail -- Where a currency conversion's rate came from          *
 *                                                                         *
 *    Uses what the rate provider recorded during the calculation, so      *
 *    "$120 - 20%" (no rate looked up) gets no note, and "1 btc in usd"    *
 *    is labelled as using SoulverCore's built-in BTC rate.                *
 *                                                                         *
 * INPUT:   provider -- the provider used for this calculation             *
 *          rates    -- cached ECB rates or nil                            *
 *                                                                         *
 * OUTPUT:  "ECB rate 2026-11-20", "built-in BTC rate (may be outdated)",  *
 *          or nil when no rate was looked up                              *
 *                                                                         *
 * HISTORY:                                                                *
 *   11/21/2026 AS : Created.                                              *
 *=========================================================================*/
func currencyDetail(provider: CachedECBRateProvider,
                    rates: CachedRates?) -> String?
{
    if !provider.fallbackCodes.isEmpty
    {
        let codes = provider.fallbackCodes.sorted().joined(separator: ", ")
        return "built-in \(codes) rate (may be outdated)"
    }
    if !provider.answeredCodes.isEmpty, let rates
    {
        return "ECB rate \(rates.date)"
    }
    return nil
}


/***************************************************************************
 * evaluate -- Calculate formatted and unformatted results                 *
 *                                                                         *
 *    Returns nil for anything that isn't really a calculation: failures,  *
 *    empty results, and input that just echoes back ("12" -> "12"), so    *
 *    Alfred can fall through to its normal results.                       *
 *                                                                         *
 * INPUT:   query -- what the user typed                                   *
 *          rates -- cached ECB rates or nil                               *
 *                                                                         *
 * OUTPUT:  Answer, or nil when there is nothing worth showing             *
 *                                                                         *
 * HISTORY:                                                                *
 *   11/21/2026 AS : Created.                                              *
 *=========================================================================*/
func evaluate(_ query: String, rates: CachedRates?) -> Answer?
{
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return nil }

    if let date = weekdayInSpan(trimmed)
    {
        let isoDay = DateFormatter()
        isoDay.dateFormat = "yyyy-MM-dd"
        return Answer(formatted: longDate(date), raw: isoDay.string(from: date),
                      detail: relativeDays(date), kind: .time)
    }

    let expression = normaliseTemperatures(trimmed)

    let provider = CachedECBRateProvider(rates)
    let calculator = Calculator(customization: makeCustomization(provider: provider))
    calculator.formattingPreferences = displayPreferences()
    let result = calculator.calculate(expression)
    if result.isEmptyResult || result.isFailedResult { return nil }

    var formatted = result.stringValue
    if formatted.isEmpty || formatted == trimmed { return nil }

    calculator.formattingPreferences = .unformatted
    var raw = calculator.calculate(expression).stringValue
    if raw.isEmpty { raw = formatted }

    var detail: String? = nil
    var kind = AnswerKind.math
    if case .date(let datestamp) = result.evaluationResult
    {
        kind = .time
        if hasClockTime(datestamp)
        {
            detail = dateDetail(datestamp)
        }
        else
        {
            formatted = longDate(datestamp.date,
                                 zone: datestamp.timezone ?? .current)
            detail = relativeDays(datestamp.date)
        }
    }
    else
    {
        detail = currencyDetail(provider: provider, rates: rates)
        let isConversion = detail != nil
            || trimmed.lowercased().contains(/\s(in|to|as|into)\s/)
        kind = isConversion ? .conversion : .math
    }
    return Answer(formatted: formatted, raw: raw, detail: detail, kind: kind)
}


//--------------------------------------------------------------------------
// Output
//--------------------------------------------------------------------------

func printJSON(_ object: [String: Any])
{
    guard let data = try? JSONSerialization.data(withJSONObject: object)
    else
    {
        return
    }
    FileHandle.standardOutput.write(data)
}


/***************************************************************************
 * answerItem -- One Alfred result row for an answer                       *
 *                                                                         *
 *    Shared by the live calculator and the history list. Modifiers match  *
 *    the workflow's connections: cmd copies the unformatted value, alt    *
 *    pastes into the frontmost app, ctrl opens the actions list, shift    *
 *    puts the answer in Alfred's search box to keep calculating. The      *
 *    variables let the --record step that runs after ↩ / ⌘↩ / ⌥↩ save     *
 *    the calculation to history, and --stash hand it to the actions list. *
 *                                                                         *
 * INPUT:   query      -- the calculation as typed                         *
 *          answer     -- its result                                       *
 *          title      -- row title (the answer live, the query in history)*
 *          subtitle   -- row subtitle                                     *
 *          icon       -- icon path inside the workflow                    *
 *          autocomplete -- text ⇥ puts after the filter's keyword         *
 *                                                                         *
 * OUTPUT:  Script Filter item dictionary                                  *
 *                                                                         *
 * WARNINGS:   Alfred always puts the filter's keyword in front of the     *
 *             autocomplete text, so ⇥ can't replace the search box. That  *
 *             is why "keep calculating" is ⇧↩ (an AppleScript search)     *
 *             rather than ⇥.                                              *
 *                                                                         *
 * HISTORY:                                                                *
 *   11/23/2026 AS : Created, split out of scriptFilterOutput.             *
 *   11/23/2026 AS : ⇧↩ keep calculating, after ⇥ gave "6143.3 lb".        *
 *=========================================================================*/
func answerItem(query: String, answer: Answer, title: String, subtitle: String,
                icon: String, autocomplete: String) -> [String: Any]
{
    [
        "title": title,
        "subtitle": subtitle,
        "arg": answer.formatted,
        "autocomplete": autocomplete,
        "icon": ["path": icon],
        "text": ["copy": answer.formatted, "largetype": answer.formatted],
        "variables": [
            "calc_query": query,
            "calc_result": answer.formatted,
            "calc_raw": answer.raw,
            "calc_kind": answer.kind.rawValue,
        ],
        "mods": [
            "cmd": ["arg": answer.raw, "subtitle": "Copy unformatted: \(answer.raw)"],
            "alt": ["arg": answer.formatted, "subtitle": "Paste into front app"],
            "ctrl": ["arg": query, "subtitle": "More actions… (copy question, both, remove)"],
            "shift": ["arg": alfredSearchText(answer.formatted),
                      "subtitle": "Keep calculating with \(answer.formatted)"],
        ],
    ]
}


/***************************************************************************
 * scriptFilterOutput -- Alfred Script Filter JSON for a query             *
 *                                                                         *
 *    One item: the formatted answer. ⇥ leaves the search box as typed:    *
 *    Alfred puts the filter's keyword in front of the autocomplete text,  *
 *    so the answer itself would come out as "6143.3 lb". ⇧↩ is the way    *
 *    to keep calculating with the answer (see answerItem).                *
 *                                                                         *
 * INPUT:   query          -- full query including the keyword character   *
 *          keywordInQuery -- true when the first character is the         *
 *                            filter's keyword (keyword-free filters)      *
 *          rates          -- cached ECB rates or nil                      *
 *                                                                         *
 * OUTPUT:  {"items": [...]}; an empty list when there is no answer        *
 *                                                                         *
 * HISTORY:                                                                *
 *   11/21/2026 AS : Created.                                              *
 *   11/23/2026 AS : Item built by answerItem so history can reuse it.     *
 *   11/23/2026 AS : ⇥ keeps the query; the answer moved to ⇧↩.            *
 *=========================================================================*/
func scriptFilterOutput(_ query: String, keywordInQuery: Bool,
                        rates: CachedRates?) -> [String: Any]
{
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard let answer = evaluate(trimmed, rates: rates) else { return ["items": []] }

    let subtitle = [trimmed, answer.detail]
        .compactMap { $0 }
        .joined(separator: "  ·  ")
    // Alfred adds the keyword back, so leave it out here or it doubles up.
    let afterKeyword = keywordInQuery ? String(query.dropFirst()) : query
    let item = answerItem(query: trimmed, answer: answer, title: answer.formatted,
                          subtitle: subtitle, icon: "icon.png",
                          autocomplete: afterKeyword)
    return ["items": [item]]
}


// Characters with a keyword-free Script Filter. Keep in sync with
// LEAD_CHARS in build.sh.
let LEAD_CHARACTERS: Set<Character> =
    ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", ".", "-", "(", "$", "€", "£"]


/***************************************************************************
 * alfredSearchText -- What the "Calculate" Universal Action types         *
 *                                                                         *
 *    Selected text that starts with a digit, $, € and so on already       *
 *    triggers a keyword-free filter, so it goes in as is. Anything else   *
 *    ("monday in 3 weeks", "rent 450 + 300") needs the word keyword in    *
 *    front, as does everything when keyword-free mode is turned off.      *
 *                                                                         *
 * INPUT:   selection -- text from the Universal Action, may span lines    *
 *                                                                         *
 * OUTPUT:  One line for Alfred's search box                               *
 *                                                                         *
 * HISTORY:                                                                *
 *   11/23/2026 AS : Created.                                              *
 *=========================================================================*/
func alfredSearchText(_ selection: String) -> String
{
    // Alfred's search box is one line.
    let text = selection.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    if Settings.current.calculateWithoutKeyword,
       let first = text.first, LEAD_CHARACTERS.contains(first)
    {
        return text
    }
    let keyword = ProcessInfo.processInfo.environment["word_keyword"] ?? ""
    return "\(keyword.isEmpty ? "=" : keyword) \(text)"
}


//--------------------------------------------------------------------------
// Entry point
//
//   soulvercalc <query>            Script Filter JSON
//   soulvercalc --lead <query>     Same, from a keyword-free leading-character
//                                  filter; empty when that's turned off
//   soulvercalc --history <filter> History list, live answer first
//   soulvercalc --record <arg>     Save calc_* variables to history, echo arg
//   soulvercalc --forget <query>   Remove a calculation from history
//   soulvercalc --stash            Save calc_* variables for the actions list
//   soulvercalc --actions <filter> "More actions" list for the stashed result
//   soulvercalc --pad <text> [add] Scratchpad (Alfred UI) update JSON, with
//                                  optional text appended below <text>
//   soulvercalc --search-text <s>  Search-box text for the Calculate action
//   soulvercalc --refresh-rates    Fetch ECB rates now (exit 1 on failure)
//--------------------------------------------------------------------------

var arguments = Array(CommandLine.arguments.dropFirst())

switch arguments.first
{
case "--refresh-rates":
    exit(await refreshRates() ? 0 : 1)
case "--record":
    recordFromEnvironment()
    // The argument is what Alfred copies or pastes next, so pass it on
    // untouched (no trailing newline).
    FileHandle.standardOutput.write(Data(arguments.dropFirst().joined(separator: " ").utf8))
    exit(0)
case "--forget":
    forgetCalculation(arguments.dropFirst().joined(separator: " "))
    exit(0)
case "--stash":
    stashFromEnvironment()
    exit(0)
case "--actions":
    printJSON(actionsOutput(arguments.dropFirst().joined(separator: " ")))
    exit(0)
case "--search-text":
    FileHandle.standardOutput.write(
        Data(alfredSearchText(arguments.dropFirst().joined(separator: " ")).utf8))
    exit(0)
default:
    break
}

// Keyword-free filters pass their keyword character as the start of the
// query; scriptFilterOutput needs to know for ⇥.
let fromLeadFilter = arguments.first == "--lead"
if fromLeadFilter
{
    if !Settings.current.calculateWithoutKeyword
    {
        printJSON(["items": []])
        exit(0)
    }
    arguments.removeFirst()
}

let rates = loadCachedRates()
refreshIfStale(rates)

switch arguments.first
{
case "--history":
    printJSON(historyOutput(arguments.dropFirst().joined(separator: " "),
                            rates: rates))
case "--pad":
    // Two separate arguments, not joined: the editor text, then optional
    // text to add (from the "Add to Calculator Scratchpad" Universal Action).
    let padArguments = Array(arguments.dropFirst())
    printJSON(scratchpadOutput(padArguments.first ?? "",
                               adding: padArguments.dropFirst().first ?? "",
                               rates: rates))
default:
    printJSON(scriptFilterOutput(arguments.joined(separator: " "),
                                 keywordInQuery: fromLeadFilter, rates: rates))
}
