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
          21
        ]
      }
    }
  },
  "version": 2
}
```
