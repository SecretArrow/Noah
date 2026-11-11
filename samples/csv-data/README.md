# Data Studio (CSV) (sample module)

A per-chat **CSV analysis studio**: paste a dataset right after the
command, then explore it with previews, statistics, filters and in-chat
ASCII charts — no network, everything scoped to this chat.

```
Data Studio · /csv
├─ load <name> \n <CSV lines>   parse + store a dataset
├─ sample                       built-in demo dataset (coffee shop sales)
├─ list / remove <name>         dataset management
├─ head <name> [n]              fixed-width table preview
├─ stats <name>                 per-column type, min/max/mean/median/std, uniques
├─ chart <name> <col>           ASCII bar chart (text) or histogram (numeric)
├─ top <name> <col> [n]         most frequent values with percentages
├─ sort <name> <col> [desc]     numeric-aware sorted preview
├─ filter <name> <col> <op> <value>   = != > < >= <= contains
├─ sum|avg|min|max|count <name> <col>
└─ help
```

## The parser

A real **RFC 4180** state machine, not `split(',')`: quoted fields,
escaped quotes (`""`), commas and newlines inside quotes, CRLF handling,
and automatic delimiter detection between `,` `;` and tab (counted
outside quotes on the header line). Column types are inferred per column
(≥80% numeric over the first 200 rows → numeric), and every numeric
command guards against dirty cells instead of producing `NaN`.

## Per-chat datasets

Each dataset is one `storage` value (≤56 KB enforced at load with a clear
error), so datasets can never leak between chats and the 1 MB per-chat
budget holds. `removeall` wipes the chat's studio in one command.

## Output discipline

Every command respects the run output cap: tables preview 12 rows with
20-char cells, charts cap at 8 bars / 8 histogram buckets with scaled
`█` widths, and filters show the first 8 matches with a count. Numbers
render through a 6-significant-digit formatter that never outputs
floating-point noise.

## Files

- `module.json` — manifest (`storage` only; command `csv`)
- `main.js` — command router + RFC 4180 parser + stats/chart engine

## Try it

1. Install the ZIP: **Settings → Modules → Install module**.
2. `/csv sample`
3. `/csv stats sample`
4. `/csv chart sample category`
5. `/csv filter sample revenue > 1000`
