Knowledge base for secure-linux-diagnose (owner: U2). One problem per line in the *.tsv files, 22 tab-separated columns:

 1 id            lower-case words joined by dashes (unique)
 2 area          boot disks memory cpu thermal power network audio graphics input devices software security accounts windows performance homeassistant maintenance
 3 applies_to    any | fedora | debian | installed | rescue | live (comma list); "+t" = needs the files of the installed system
 4 cost          quick | full
 5 detector      expression: TERM && TERM || TERM ; terms: cmd:KEY~REGEX[#N] file:PATH~REGEX glob:PATTERN health:PART[:ITEM]=ST[,ST][~REGEX]
                 val:KEY>=N env:NAME choice:KEY=VALUE fn:NAME   (a leading ! negates). Full description: hw/health/diagnose-lib.sh
 6 severity      info|warn|fail, optionally ";LEVEL=EXPR" to raise it
 7 impact        0-100, orders problems of the same severity
 8-10 title, what, why        plain English, no jargon, Australian spelling; {detail} is replaced by what the detector saw
 11 safe_level   safe | asks | risky
 12 auto_fixable yes | no
 13 fix_action   a secure-linux-repair --action name (menu action or fix-*) or -
 14 fix_args     default arguments (the detector can supply better ones) or -
 15-17 fix_summary, backup_first, undo
 18 time_estimate
 19 learn_more   docs/notes/diagnose-guide.md anchor
 20 manual       what to do by hand
 21 flags        hwfail (draws the "Back up your files now" card) backup reboot maint (only in autopilot) or -
 22 notes        for developers (never empty)

correlate.tsv: winner, suppressed ids (comma separated), note. When the winner is found the others are not reported separately.
Rules checked by tests/diagnose/run.sh: field lengths, banned jargon (tests/diagnose/banned-words.txt), US spellings
(tests/diagnose/us-spellings.txt), every detector refers to something that exists, every problem has a test case.
