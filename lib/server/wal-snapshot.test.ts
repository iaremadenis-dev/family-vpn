import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { DatabaseSync } from "node:sqlite";
import { describe, test } from "node:test";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const tool = path.join(root, "panel", "archive-tool.mjs");

describe("sqlite wal snapshot", () => {
  test("VACUUM INTO keeps a committed row that a plain file copy loses", () => {
    const dir = mkdtempSync(path.join(tmpdir(), "family-vpn-wal-"));
    const file = path.join(dir, "family-vpn.sqlite");
    const db = new DatabaseSync(file);
    db.exec("PRAGMA journal_mode = WAL");
    db.exec("CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL)");
    db.exec("INSERT INTO notes (id, body) VALUES (1, 'checkpointed')");
    db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    db.prepare("INSERT INTO notes (id, body) VALUES (?, ?)").run(2, "only-wal");

    const naivePath = path.join(dir, "naive.sqlite");
    copyFileSync(file, naivePath);
    const naive = new DatabaseSync(naivePath);
    const naiveBodies = naive.prepare("SELECT body FROM notes ORDER BY id").all().map((row) => String(row.body));
    naive.close();
    assert.deepEqual(naiveBodies, ["checkpointed"]);

    const destination = path.join(dir, "snap.sqlite");
    const snapped = spawnSync(process.execPath, [tool, "snapshot", file, destination], { encoding: "utf8" });
    assert.equal(snapped.status, 0, snapped.stderr);
    const snapshot = new DatabaseSync(destination);
    const bodies = snapshot.prepare("SELECT body FROM notes ORDER BY id").all().map((row) => String(row.body));
    snapshot.close();
    db.close();
    assert.deepEqual(bodies, ["checkpointed", "only-wal"]);
    rmSync(dir, { recursive: true, force: true });
  });
});
