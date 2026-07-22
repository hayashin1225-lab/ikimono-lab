"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const core = require("../assets/js/core.js");

const gameData = {
  meta: {
    titleId: "test-title",
    gameVersion: "1.0.0",
    storageKey: "test-save"
  }
};

function createStorage(initialValue) {
  const values = new Map();
  if (initialValue !== undefined) {
    values.set(gameData.meta.storageKey, initialValue);
  }
  return {
    getItem(key) {
      return values.has(key) ? values.get(key) : null;
    },
    setItem(key, value) {
      values.set(key, String(value));
    },
    removeItem(key) {
      values.delete(key);
    },
    value(key) {
      return values.get(key);
    }
  };
}

test("初期状態はセーブデータ契約を満たす", function () {
  const state = core.createInitialState(gameData, new Date("2026-07-22T00:00:00Z"));
  const result = core.validateState(state, gameData);

  assert.equal(result.ok, true);
  assert.equal(state.schemaVersion, 1);
  assert.equal(state.titleId, "test-title");
  assert.deepEqual(state.collection, {});
  assert.deepEqual(state.achievements, []);
  assert.equal(state.exportedCollectionRecord, null);
});

test("主要行動後の状態を保存し、再起動相当で復元できる", function () {
  const storage = createStorage();
  let state = core.createInitialState(gameData, new Date("2026-07-22T00:00:00Z"));
  state = core.selectCondition(state, "condition-a");
  state = core.addDiscovery(state, "sample-a", 2, new Date("2026-07-22T00:01:00Z"));
  state = core.saveState(storage, gameData, state, new Date("2026-07-22T00:02:00Z"));

  const loaded = core.loadState(storage, gameData);
  assert.equal(loaded.recovery, null);
  assert.deepEqual(loaded.state, state);
  assert.equal(loaded.state.progress.screen, "result");
  assert.equal(loaded.state.collection["sample-a"].count, 1);
});

test("解析不能な保存データは上書きせず復旧情報と初期状態を返す", function () {
  const broken = "{not-json";
  const storage = createStorage(broken);
  const loaded = core.loadState(storage, gameData, new Date("2026-07-22T00:00:00Z"));

  assert.ok(loaded.recovery);
  assert.equal(loaded.recovery.raw, broken);
  assert.equal(storage.value(gameData.meta.storageKey), broken);
  assert.equal(loaded.state.progress.screen, "title");
});

test("同じ記録を再読込しても重複追加や進捗後退が起きない", function () {
  let exportedState = core.createInitialState(gameData, new Date("2026-07-22T00:00:00Z"));
  exportedState = core.addDiscovery(exportedState, "sample-a", 2, new Date("2026-07-22T00:01:00Z"));
  exportedState = core.addDiscovery(exportedState, "sample-b", 2, new Date("2026-07-22T00:02:00Z"));
  const record = core.createPortableRecord(exportedState, new Date("2026-07-22T00:03:00Z"));

  let current = core.createInitialState(gameData, new Date("2026-07-22T01:00:00Z"));
  current = core.addDiscovery(current, "sample-a", 2, new Date("2026-07-22T01:01:00Z"));
  current = core.addDiscovery(current, "sample-a", 2, new Date("2026-07-22T01:02:00Z"));
  current = core.addDiscovery(current, "sample-a", 2, new Date("2026-07-22T01:03:00Z"));

  const first = core.importRecord(current, record, gameData);
  const second = core.importRecord(first.state, record, gameData);

  assert.equal(first.ok, true);
  assert.equal(second.ok, true);
  assert.equal(second.state.collection["sample-a"].count, 3);
  assert.equal(second.state.collection["sample-b"].count, 1);
  assert.equal(second.state.progress.actionCount, 3);
  assert.equal(second.state.progress.endingUnlocked, true);
  assert.deepEqual(second.state, first.state);
});

test("別作品の記録は読み込まない", function () {
  const state = core.createInitialState(gameData, new Date("2026-07-22T00:00:00Z"));
  const record = core.createPortableRecord(state, new Date("2026-07-22T00:01:00Z"));
  record.titleId = "other-title";

  const result = core.importRecord(state, record, gameData);
  assert.equal(result.ok, false);
  assert.match(result.errors.join(" "), /別作品/);
});

test("危険な標本IDを含む記録は読み込まない", function () {
  const state = core.createInitialState(gameData, new Date("2026-07-22T00:00:00Z"));
  const record = core.createPortableRecord(state, new Date("2026-07-22T00:01:00Z"));
  record.collection = JSON.parse('{"__proto__":{"id":"__proto__","count":1,"discoveredAt":"2026-07-22T00:00:00.000Z"}}');

  const result = core.importRecord(state, record, gameData);
  assert.equal(result.ok, false);
  assert.match(result.errors.join(" "), /IDが不正/);
  assert.equal({}.polluted, undefined);
});

test("未定義画面への遷移を拒否する", function () {
  const state = core.createInitialState(gameData, new Date("2026-07-22T00:00:00Z"));
  assert.throws(function () {
    core.setScreen(state, "unknown");
  }, /未定義の画面/);
});
