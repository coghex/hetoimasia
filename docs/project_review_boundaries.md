# Project review sweep cursor

Machine-owned state for the `project-review` workflow: each repository's
exclusive older PR boundary, the units completed batches reviewed, the direct
history endpoint, and the units a user explicitly excluded. PR selection always
starts at the latest merge and stops before its boundary; a clean batch records
reviewed coverage exactly as a finding-bearing batch does.

Written by `project_review_cursor.py`. Edit it through that helper rather than
by hand: the payload below is parsed strictly, and an edit it cannot read stops
the next sweep instead of being ignored.

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
          137
        ]
      }
    }
  },
  "version": 2
}
```
