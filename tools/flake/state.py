"""Transactional local history shared by every linked worktree.

The database owns registrations, deferrals, proposals and completed measurements.
Completed attempt rows are immutable. Markdown is a regenerable view, never an
input. The run lock serializes execution, not readers or unrelated repository work.
"""
from __future__ import annotations

from contextlib import contextmanager
import fcntl
import json
from pathlib import Path
import sqlite3
import time
import uuid

from common import LabError, atomic_json, atomic_text, utc

SCHEMA = 1


class State:
    def __init__(self, directory: Path):
        self.directory = directory
        directory.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(directory / "lab.sqlite3", timeout=30)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA busy_timeout=30000")
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA synchronous=FULL")
        version = self.db.execute("PRAGMA user_version").fetchone()[0]
        if version not in (0, SCHEMA):
            raise LabError(f"unsupported lab schema {version}; this tool supports {SCHEMA}")
        if version == 0:
            self.db.executescript("""
                BEGIN IMMEDIATE;
                CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, document TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS registrations (
                    id TEXT PRIMARY KEY, document TEXT NOT NULL, created TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS deferrals (
                    id TEXT PRIMARY KEY, reason TEXT NOT NULL, resume_when TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS events (
                    id INTEGER PRIMARY KEY, at TEXT NOT NULL, kind TEXT NOT NULL, document TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS proposals (
                    id TEXT PRIMARY KEY, probe_id TEXT UNIQUE NOT NULL, status TEXT NOT NULL,
                    document TEXT NOT NULL, created TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS runs (
                    id TEXT PRIMARY KEY, probe_id TEXT NOT NULL, mode TEXT NOT NULL,
                    revision TEXT NOT NULL, identity TEXT NOT NULL, started TEXT NOT NULL,
                    heartbeat TEXT NOT NULL, state TEXT NOT NULL, finished_epoch REAL,
                    document TEXT NOT NULL, summary TEXT);
                CREATE TABLE IF NOT EXISTS attempts (
                    run_id TEXT NOT NULL REFERENCES runs(id), number INTEGER NOT NULL,
                    state TEXT NOT NULL, document TEXT NOT NULL, PRIMARY KEY(run_id, number));
                PRAGMA user_version=1;
                COMMIT;
            """)
        self.db.execute("PRAGMA foreign_keys=ON")

    @contextmanager
    def transaction(self):
        self.db.execute("BEGIN IMMEDIATE")
        try:
            yield
            self.db.commit()
        except BaseException:
            self.db.rollback()
            raise

    @contextmanager
    def execution_lock(self):
        with (self.directory / "execution.lock").open("a+") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                yield None
                return
            try:
                yield lock.fileno()
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)

    def event(self, kind, document):
        self.db.execute("INSERT INTO events(at,kind,document) VALUES(?,?,?)",
                        (utc(), kind, json.dumps(document, sort_keys=True)))

    def inventory(self, revision=None, probes=None):
        if probes is not None:
            with self.transaction():
                self.db.execute("INSERT OR REPLACE INTO metadata VALUES('inventory',?)",
                                (json.dumps(dict(revision=revision, probes=list(probes))),))
        row = self.db.execute("SELECT document FROM metadata WHERE key='inventory'").fetchone()
        return json.loads(row[0]) if row else dict(probes=[])

    def registrations(self):
        return [json.loads(r[0]) for r in self.db.execute("SELECT document FROM registrations ORDER BY id")]

    def register(self, p):
        with self.transaction():
            old = self.db.execute("SELECT document FROM registrations WHERE id=?", (p["id"],)).fetchone()
            if old and json.loads(old[0]) != p:
                raise LabError("registration exists with different settings; use a new versioned id")
            self.db.execute("INSERT OR IGNORE INTO registrations VALUES(?,?,?)", (p["id"], json.dumps(p), utc()))
            if not old:
                self.event("registered", p)

    def deferred(self):
        return {r["id"]: dict(r) for r in self.db.execute("SELECT * FROM deferrals")}

    def defer(self, key, reason, resume_when):
        if not reason.strip() or not resume_when.strip():
            raise LabError("deferral needs a reason and objective resume condition")
        with self.transaction():
            self.db.execute("INSERT OR REPLACE INTO deferrals VALUES(?,?,?)", (key, reason, resume_when))
            self.event("deferred", dict(id=key, reason=reason, resume_when=resume_when))

    def resume(self, key, evidence):
        if not evidence.strip():
            raise LabError("resume needs evidence that its condition is satisfied")
        with self.transaction():
            if not self.db.execute("DELETE FROM deferrals WHERE id=?", (key,)).rowcount:
                raise LabError("probe is not deferred")
            self.event("resumed", dict(id=key, evidence=evidence))

    def proposals(self):
        return [dict(r) | {"document": json.loads(r["document"])} for r in self.db.execute("SELECT * FROM proposals ORDER BY created")]

    def propose(self, p):
        required = {"probe_id", "question", "gap", "scenario", "oracle", "cost", "tier", "revision"}
        if not isinstance(p, dict) or set(p) != required or not all(isinstance(v, str) and v.strip() for v in p.values()):
            raise LabError("proposal needs exactly " + ", ".join(sorted(required)))
        with self.transaction():
            existing = self.db.execute("SELECT id FROM proposals WHERE probe_id=?", (p["probe_id"],)).fetchone()
            if existing:
                return existing[0]
            identifier = str(uuid.uuid4())
            self.db.execute("INSERT INTO proposals VALUES(?,?,?,?,?)",
                            (identifier, p["probe_id"], "pending", json.dumps(p), utc()))
            self.event("proposed", dict(id=identifier, **p))
            return identifier

    def close_proposal(self, identifier, status, note):
        if status not in ("accepted", "rejected", "implemented", "superseded") or not note.strip():
            raise LabError("proposal disposition needs status and a nonblank note")
        with self.transaction():
            if not self.db.execute("UPDATE proposals SET status=? WHERE id=?", (status, identifier)).rowcount:
                raise LabError("unknown proposal")
            self.event("proposal-disposition", dict(id=identifier, status=status, note=note))

    def histories(self):
        return [dict(r) for r in self.db.execute("SELECT * FROM runs WHERE finished_epoch IS NOT NULL ORDER BY finished_epoch DESC")]

    def begin(self, identifier, probe, mode, revision, identity, document):
        with self.transaction():
            self.db.execute("INSERT INTO runs VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                            (identifier, probe["id"], mode, revision, identity, utc(), utc(), "preparing", None,
                             json.dumps(document), None))

    def heartbeat(self, identifier):
        with self.transaction():
            self.db.execute("UPDATE runs SET heartbeat=? WHERE id=? AND finished_epoch IS NULL", (utc(), identifier))

    def prepared(self, identifier, document):
        with self.transaction():
            self.db.execute("UPDATE runs SET document=?,state='running',heartbeat=? WHERE id=? AND finished_epoch IS NULL",
                            (json.dumps(document), utc(), identifier))

    def start_attempt(self, identifier, number, document):
        with self.transaction():
            self.db.execute("INSERT INTO attempts VALUES(?,?,'running',?)", (identifier, number, json.dumps(document)))

    def finish_attempt(self, identifier, number, result):
        with self.transaction():
            old = self.db.execute("SELECT state,document FROM attempts WHERE run_id=? AND number=?", (identifier, number)).fetchone()
            if old is None:
                raise LabError("attempt was never started")
            if old["state"] != "running":
                if json.loads(old["document"]) != result:
                    raise LabError("completed attempt is immutable")
                return
            self.db.execute("UPDATE attempts SET state=?,document=? WHERE run_id=? AND number=?",
                            (result["outcome"], json.dumps(result), identifier, number))

    def finish(self, identifier, state, summary):
        with self.transaction():
            row = self.db.execute("SELECT finished_epoch FROM runs WHERE id=?", (identifier,)).fetchone()
            if row is None:
                raise LabError("unknown run")
            if row[0] is not None:
                return
            self.db.execute("UPDATE runs SET state=?,summary=?,finished_epoch=?,heartbeat=? WHERE id=?",
                            (state, json.dumps(summary), time.time(), utc(), identifier))

    def attempts(self, identifier):
        return [dict(r) | {"document": json.loads(r["document"])} for r in self.db.execute(
            "SELECT * FROM attempts WHERE run_id=? ORDER BY number", (identifier,))]

    def snapshot(self):
        return dict(schema_version=SCHEMA, generated=utc(), inventory=self.inventory(),
                    runs=[dict(r) | {"document": json.loads(r["document"]),
                                     "summary": json.loads(r["summary"]) if r["summary"] else None,
                                     "attempts": self.attempts(r["id"])}
                          for r in self.db.execute("SELECT * FROM runs ORDER BY started DESC")],
                    registrations=self.registrations(),
                    events=[dict(r) for r in self.db.execute("SELECT * FROM events ORDER BY id")],
                    deferrals=self.deferred(), proposals=self.proposals())

    def render(self):
        # Serialize reading and replacement: a slower renderer must not replace
        # a newer view. Crash after a DB commit is repaired by the next status.
        with self.transaction():
            snap = self.snapshot()
            lines = ["# Hetoimasia local test and flake coordinator", "", f"Updated {snap['generated']}", "",
                     "Generated from lab.sqlite3. Do not edit this page. History is local to this clone.", "",
                     "## Inventory", ""]
            for p in snap["inventory"]["probes"]:
                lines.append(f"- **{p['id']}** ({p['kind']}, {'test + flake' if p['optional'] else 'flake'}): {p['description']}")
            lines += ["", "## Runs", "",
                     "| Probe | Mode | Started (UTC) | Commit | Outcome | Attempts | Evidence |",
                     "| --- | --- | --- | --- | --- | --- | --- |"]
            for r in snap["runs"]:
                if r["finished_epoch"] is not None:
                    atomic_json(self.directory / "runs" / r["id"] / "result.json", r)
                counts = {}
                for a in r["attempts"]:
                    counts[a["state"]] = counts.get(a["state"], 0) + 1
                lines.append(f"| {r['probe_id']} | {r['mode']} | {r['started']} | `{r['revision'][:12]}` | "
                             f"{r['state']} | {counts} | [run](runs/{r['id']}/result.json) |")
            lines += ["", "## Deferrals", ""]
            for key, d in snap["deferrals"].items():
                lines.append(f"- **{key}**: {d['reason']}; resume when {d['resume_when']}")
            lines += ["", "## Probe proposals", ""]
            for p in snap["proposals"]:
                lines.append(f"- **{p['probe_id']}** ({p['status']}, {p['id']}): {p['document']['question']}")
            atomic_text(self.directory / "coordinator.md", "\n".join(lines) + "\n")
        return self.directory / "coordinator.md"
