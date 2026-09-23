# Legacy project-review cursor — retained migration evidence

Current project-review state lives in the [review ledger](project_review/ledger.md),
maintained by `project_review_ledger.py`. That ledger owns current selection,
completed reviews, and direct-history progress.

This cursor was written by the former `project_review_cursor.py`, which no
longer ships with the installed workflow. The ledger helper retains a reader
for its migration data and does not write this file. Keep the original path,
marker, and payload as provenance for the ledger's imported coverage; do not
use it as the current review queue or update its recorded state by hand.

<!-- project-review:cursor:v2 -->

```json
{
  "repositories": {
    "coghex/hetoimasia": {
      "direct": {
        "endpoint": null,
        "reviewed": []
      },
      "excluded": {
        "commits": [],
        "prs": []
      },
      "pr": {
        "endpoint": null,
        "reviewed": [
          15,
          16,
          20,
          21,
          31,
          32,
          33,
          34,
          35,
          36,
          37,
          38,
          43,
          44,
          45,
          46,
          48,
          51,
          61,
          62,
          63,
          64,
          65,
          66,
          67,
          68,
          71,
          72,
          80,
          81,
          82,
          83,
          84,
          85,
          101,
          102,
          103,
          104,
          105,
          106,
          107,
          108,
          109,
          110,
          111,
          112,
          113,
          114,
          119,
          120,
          121,
          122,
          126,
          128,
          132,
          137,
          150,
          151,
          152,
          153,
          154,
          156,
          159,
          161,
          162,
          163,
          164,
          165
        ]
      }
    }
  },
  "version": 2
}
```
