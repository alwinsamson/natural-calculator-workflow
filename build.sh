#!/usr/bin/env zsh
############################################################################
# PROJECT: Natural Calculator (Alfred workflow)                            #
#                                                                          #
# FILE: build.sh                                                           #
#                                                                          #
# AUTHOR: AS                                                               #
#                                                                          #
# START DATE: 11/21/2026                                                   #
#                                                                          #
# LAST UPDATE: 11/26/2026                                                  #
#                                                                          #
#--------------------------------------------------------------------------#
# OVERVIEW:                                                                #
#   Builds soulvercalc in release mode, copies it and SoulverCore into     #
#   Workflow/, generates Workflow/info.plist, and zips Workflow/ into      #
#   dist/NaturalCalculator.alfredworkflow. Workflow/ holds the workflow's  #
#   own files (UI, icons, screenshots) and is never deleted; only the      #
#   compiled parts and info.plist are regenerated. Safe to re-run.         #
#--------------------------------------------------------------------------#
# FUNCTIONS:                                                               #
#   make_info_plist          -- Write info.plist; readme from              #
#                               assets/workflow_readme.md                  #
#   check_dist_is_disposable -- Refuse to delete an export saved in dist/  #
#==========================================================================#
set -euo pipefail

readonly ROOT="${0:A:h}"
# The unpacked workflow, as in Alfred's own workflow repositories.
readonly STAGE="${ROOT}/Workflow"
readonly OUTPUT="${ROOT}/dist/NaturalCalculator.alfredworkflow"
# Checksum of the last package this script wrote (see check_dist_is_disposable).
readonly STAMP="${ROOT}/dist/.build_checksum"
# One Script Filter per leading character lets a calculation start straight
# from Alfred's search box without a keyword: the filter whose keyword is
# the first character typed picks the query up.
# "=" covers queries that start with a word, like "= days until 25 dec".
readonly LEAD_CHARS=(0 1 2 3 4 5 6 7 8 9 . - "(" '$' "€" "£")
readonly MOD_CMD=1048576
readonly MOD_ALT=524288
readonly MOD_CTRL=262144
readonly MOD_SHIFT=131072


make_info_plist()
{
    local filters_json
    filters_json="$(printf '%s\n' "${LEAD_CHARS[@]}" | jq -R . | jq -s .)"

    jq -n --argjson leads "${filters_json}" --arg q "'" \
        --rawfile readme "${ROOT}/assets/workflow_readme.md" \
        --slurpfile layoutfile "${ROOT}/assets/workflow_layout.json" '
      def uid(n): "5C0A1C00-0000-4000-8000-\(n | tostring | ("000000000000" + .) | .[-12:])";
      def filter(n; kw; script): {
        uid: uid(n),
        type: "alfred.workflow.input.scriptfilter",
        version: 3,
        config: {
          keyword: kw, withspace: false, argumenttype: 1,
          title: "Calculate", subtext: "Natural language maths, units, currency and time",
          type: 11, scriptargtype: 1, escaping: 102, script: script, scriptfile: "",
          alfredfiltersresults: false, alfredfiltersresultsmatchmode: 0,
          argumenttreatemptyqueryasnil: false, argumenttrimmode: 0,
          queuemode: 2, queuedelaymode: 0, queuedelaycustom: 3,
          queuedelayimmediatelyinitially: true, runningsubtext: "",
          skipuniversalaction: true
        }
      };
      def script(n; body): {
        uid: uid(n), type: "alfred.workflow.action.script", version: 2,
        config: { concurrently: false, escaping: 102, script: body,
                  scriptargtype: 1, scriptfile: "", type: 11 }
      };
      def link(dest; mods): { destinationuid: dest, modifiers: mods,
                              modifiersubtext: "", vitoclose: false };
      # One branch of a Conditional. ("label" is a jq keyword, hence "branch".)
      def routed(conditional; dest; branch): link(dest; 0)
        + { sourceoutputuid: (conditional.config.conditions[]
                              | select(.outputlabel == branch) | .uid) };
      ($leads | to_entries | map(
          filter(.key + 1; .value;
                 "./soulvercalc --lead \(.value | @sh)\"${1:-}\""))) as $leadFilters
      | filter(0; "{var:word_keyword}"; "./soulvercalc \"${1:-}\"") as $equalsFilter
      | ($leadFilters + [$equalsFilter]) as $filters
      | (filter(907; "{var:history_keyword}"; "./soulvercalc --history \"${1:-}\"")
         | .config += { withspace: true, title: "Calculator History",
                        subtext: "Search past calculations, or type a new one" })
        as $historyFilter
      | { uid: uid(900), type: "alfred.workflow.output.clipboard", version: 3,
          config: { clipboardtext: "{query}", autopaste: false, transient: false,
                    ignoredynamicplaceholders: false } } as $clipboard
      | { uid: uid(903), type: "alfred.workflow.output.clipboard", version: 3,
          config: { clipboardtext: "{query}", autopaste: true, transient: false,
                    ignoredynamicplaceholders: false } } as $paste
      # Save the calculation to history, then pass the result on unchanged.
      # Two copies so the copy and paste paths stay separate after the step.
      | script(904; "./soulvercalc --record \"${1}\"") as $recordCopy
      | script(905; "./soulvercalc --record \"${1}\"") as $recordPaste
      | script(906; "./soulvercalc --forget \"${1}\"") as $forget
      # ⌃↩ "More actions": stash the row, then re-open Alfred on the actions
      # list through an External Trigger (variables do not survive that hop,
      # hence the file). $q is a single quote, passed in with --arg because
      # this jq program is itself inside shell single quotes.
      | script(908; "./soulvercalc --stash && /usr/bin/osascript -e \($q)on run argv\($q) -e \($q)tell application id \"com.runningwithcrayons.Alfred\" to run trigger \"actions\" in workflow (item 1 of argv) with argument \"\"\($q) -e \($q)end run\($q) \"${alfred_workflow_bundleid}\"") as $stash
      | { uid: uid(909), type: "alfred.workflow.trigger.external", version: 1,
          config: { triggerid: "actions", availableviaurlhandler: false } } as $actionsTrigger
      # Only reached through the trigger above. The leading underscore keeps
      # it out of normal typing ("calc" would otherwise list it).
      | (filter(910; "_calc_actions"; "./soulvercalc --actions \"${1:-}\"")
         | .config += { withspace: true, title: "Calculator Actions",
                        subtext: "Actions for the selected calculation" })
        as $actionsFilter
      | { uid: uid(911), type: "alfred.workflow.utility.conditional", version: 1,
          config: { hideelse: true, elselabel: "",
                    conditions: [ "copy", "paste", "search", "forget" ]
                      | to_entries | map({ uid: uid(9110 + .key), outputlabel: .value,
                                          inputstring: "{var:calc_action}", matchstring: .value,
                                          matchmode: 0, matchcasesensitive: false }) } }
        as $route
      | script(912; "/usr/bin/osascript -e \($q)on run argv\($q) -e \($q)tell application id \"com.runningwithcrayons.Alfred\" to search (item 1 of argv)\($q) -e \($q)end run\($q) \"${1}\"") as $putInSearch
      | { uid: uid(901), type: "alfred.workflow.userinterface.alfredui", version: 1,
          config: { path: "calc.alfredui", stackview: false, launchmode: 0 } } as $pad
      | { uid: uid(902), type: "alfred.workflow.input.keyword", version: 1,
          config: { keyword: "{var:scratchpad_keyword}", withspace: false, argumenttype: 2,
                    text: "Calculator Scratchpad",
                    subtext: "Multi-line calculations with variables and a running total",
                    skipuniversalaction: true } } as $padKeyword
      # Universal Actions on selected text. "Calculate" opens Alfred with the
      # text, so the normal result row (and its keys and history) does the
      # rest; soulvercalc --search-text decides whether the word keyword is
      # needed in front. The scratchpad one passes the text to the panel,
      # which appends it.
      | { uid: uid(914), type: "alfred.workflow.trigger.universalaction", version: 1,
          config: { name: "Calculate", acceptstext: true, acceptsurls: false,
                    acceptsfiles: false, acceptsmulti: 0 } } as $uaCalculate
      | { uid: uid(915), type: "alfred.workflow.trigger.universalaction", version: 1,
          config: { name: "Add to Calculator Scratchpad", acceptstext: true,
                    acceptsurls: false, acceptsfiles: false, acceptsmulti: 0 } } as $uaPad
      | script(913; "/usr/bin/osascript -e \($q)on run argv\($q) -e \($q)tell application id \"com.runningwithcrayons.Alfred\" to search (item 1 of argv)\($q) -e \($q)end run\($q) \"$(./soulvercalc --search-text \"${1}\")\"") as $calculateInAlfred
      | ([ link($recordCopy.uid; 0), link($recordCopy.uid; '"${MOD_CMD}"'),
           link($recordPaste.uid; '"${MOD_ALT}"'), link($stash.uid; '"${MOD_CTRL}"'),
           link($putInSearch.uid; '"${MOD_SHIFT}"') ])
        as $resultLinks
      | {
          bundleid: "com.alwinsamson.calculator",
          name: "Natural Calculator",
          description: "Natural-language maths, units, currency, dates and time zones",
          createdby: "Alwin Samson",
          category: "Productivity",
          webaddress: "https://alwinsamson.com",
          variablesdontexport: [],
          version: "1.1",
          disabled: false,
          readme: $readme,
          userconfigurationconfig: [
            { type: "textfield", variable: "word_keyword", label: "Word Query Keyword",
              description: "Keyword for queries that start with a word, e.g. \"= days until 25 dec\".",
              config: { default: "=", placeholder: "=", required: false, trim: true } },
            { type: "textfield", variable: "history_keyword", label: "History Keyword",
              description: "Keyword that lists past calculations.",
              config: { default: "history", placeholder: "history", required: false, trim: true } },
            { type: "textfield", variable: "scratchpad_keyword", label: "Scratchpad Keyword",
              description: "Keyword that opens the multi-line scratchpad.",
              config: { default: "calc", placeholder: "calc", required: false, trim: true } },
            { type: "checkbox", variable: "save_history", label: "History",
              description: "Saved locally in Alfred’s workflow data folder. Turning this off stops saving; existing entries stay until removed with ⌃↩.",
              config: { default: true, text: "Save calculations I copy or paste", required: false } },
            { type: "checkbox", variable: "calculate_without_keyword", label: "Keyword-free",
              description: "Calculate as soon as a query starts with a digit, . - ( $ € or £.",
              config: { default: true, text: "Calculate without a keyword", required: false } },
            { type: "popupbutton", variable: "decimal_places", label: "Decimal Places",
              description: "Rounding for displayed results. ⌘↩ always copies the unrounded value.",
              config: { default: "2", pairs: [["0","0"],["1","1"],["2","2"],["3","3"],["4","4"],["6","6"]] } },
            { type: "checkbox", variable: "thousands_separator", label: "Formatting",
              description: "",
              config: { default: true, text: "Thousands separator (1,234 instead of 1234)", required: false } },
            { type: "popupbutton", variable: "rates_refresh_hours", label: "Currency Rates",
              description: "How often to fetch European Central Bank rates in the background. ECB publishes once per working day.",
              config: { default: "6", pairs: [["Every hour","1"],["Every 3 hours","3"],["Every 6 hours","6"],["Every 12 hours","12"],["Every day","24"]] } }
          ],
          objects: ($filters + [$historyFilter, $recordCopy, $recordPaste, $forget,
                                $stash, $actionsTrigger, $actionsFilter, $route,
                                $putInSearch, $clipboard, $paste, $pad, $padKeyword,
                                $uaCalculate, $uaPad, $calculateInAlfred]),
          connections: (
            ($filters | map({ key: .uid, value: $resultLinks }) | from_entries)
            + { ($historyFilter.uid): $resultLinks,
                ($actionsTrigger.uid): [ link($actionsFilter.uid; 0) ],
                ($actionsFilter.uid): [ link($route.uid; 0) ],
                ($route.uid): [ routed($route; $recordCopy.uid; "copy"),
                                routed($route; $recordPaste.uid; "paste"),
                                routed($route; $putInSearch.uid; "search"),
                                routed($route; $forget.uid; "forget") ],
                ($recordCopy.uid): [ link($clipboard.uid; 0) ],
                ($recordPaste.uid): [ link($paste.uid; 0) ],
                ($padKeyword.uid): [ link($pad.uid; 0) ],
                ($uaCalculate.uid): [ link($calculateInAlfred.uid; 0) ],
                ($uaPad.uid): [ link($pad.uid; 0) ],
                ($pad.uid): [ link($clipboard.uid; 0) ] }
          ),
          # Canvas positions arranged by hand in Alfred Preferences and
          # saved from an export (assets/workflow_layout.json).
          # Objects added since the last export get a default spot; the saved
          # layout wins for everything it knows about.
          uidata: ({ ($uaCalculate.uid): { xpos: 40, ypos: 2400 },
                     ($calculateInAlfred.uid): { xpos: 260, ypos: 2400 },
                     ($uaPad.uid): { xpos: 40, ypos: 2550 } } + $layoutfile[0])
        }' > "${STAGE}/info.json"

    plutil -convert xml1 -o "${STAGE}/info.plist" "${STAGE}/info.json"
    rm "${STAGE}/info.json"
    plutil -lint -s "${STAGE}/info.plist"
}


check_dist_is_disposable()
{
    # dist/ is rebuilt from scratch. An export from Alfred Preferences saved
    # there (over or next to the build output) holds canvas positions that
    # only live in Alfred, so it must not be deleted. The build records a
    # checksum of what it wrote; anything else is not ours.
    local package
    for package in "${ROOT}"/dist/*.alfredworkflow(N)
    do
        [[ -f "${STAMP}" && "$(md5 -q "${package}")" == "$(<"${STAMP}")" ]] && continue
        print -u2 "${package#${ROOT}/} wasn't made by this build (an export from Alfred?)."
        print -u2 "Move it to exports/ and copy its uidata into assets/workflow_layout.json"
        print -u2 "if you rearranged the canvas, then run ./build.sh again."
        exit 1
    done
}


check_dist_is_disposable
print "Building soulvercalc (release)..."
swift build --package-path "${ROOT}" -c release
bin_dir="$(swift build --package-path "${ROOT}" -c release --show-bin-path)"

rm -rf "${ROOT}/dist"
mkdir -p "${ROOT}/dist"
# Compiled parts are gitignored and replaced on every build. The framework
# is removed first so files dropped from a newer SoulverCore don't linger.
cp "${bin_dir}/soulvercalc" "${STAGE}/"
rm -rf "${STAGE}/SoulverCore.framework"
# ditto keeps the framework's internal symlinks; cp -R would also work but
# ditto is what Apple recommends for bundles.
ditto "${bin_dir}/SoulverCore.framework" "${STAGE}/SoulverCore.framework"
make_info_plist

# A readme image that doesn't exist shows as a broken picture in Alfred,
# so say which one is missing rather than finding out there.
for image in ${(f)"$(grep -o 'images/about/[^)]*' "${ROOT}/assets/workflow_readme.md")"}
do
    [[ -f "${STAGE}/${image}" ]] ||
        print -u2 "Warning: readme image ${image} missing (add Workflow/${image})"
done

# The binary must find SoulverCore next to it, not in .build/.
otool -l "${STAGE}/soulvercalc" | grep -q '@executable_path' || {
    print -u2 "soulvercalc has no @executable_path rpath; check Package.swift"
    exit 1
}

# Finder litters .DS_Store files; they don't belong in the package.
(cd "${STAGE}" && zip -qry "${OUTPUT}" . -x '*.DS_Store')
md5 -q "${OUTPUT}" > "${STAMP}"
print "Built ${OUTPUT} ($(du -h "${OUTPUT}" | cut -f1))"
