"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const productRoot = path.resolve(__dirname, "..");

function read(relativePath) {
  return fs.readFileSync(path.join(productRoot, relativePath), "utf8");
}

test("index.html から直接読み込む全ファイルが存在する", function () {
  const requiredFiles = [
    "index.html",
    "assets/css/app.css",
    "assets/js/core.js",
    "data/game-data.js",
    "assets/js/app.js"
  ];

  requiredFiles.forEach(function (relativePath) {
    assert.equal(fs.existsSync(path.join(productRoot, relativePath)), true, relativePath);
  });

  const html = read("index.html");
  assert.ok(html.indexOf("assets/js/core.js") < html.indexOf("data/game-data.js"));
  assert.ok(html.indexOf("data/game-data.js") < html.indexOf("assets/js/app.js"));
});

test("共通7画面が一つずつ定義されている", function () {
  const html = read("index.html");
  const expected = ["title", "hub", "condition", "result", "collection", "ending", "settings-record"];

  expected.forEach(function (screenId) {
    const pattern = new RegExp("data-screen=\\\"" + screenId + "\\\"", "g");
    assert.equal((html.match(pattern) || []).length, 1, screenId);
  });
});

test("実行時の外部通信と外部依存を含まない", function () {
  const runtimeFiles = ["index.html", "assets/js/core.js", "data/game-data.js", "assets/js/app.js", "assets/css/app.css"];

  runtimeFiles.forEach(function (relativePath) {
    const source = read(relativePath);
    assert.doesNotMatch(source, /\bfetch\s*\(/, relativePath + " contains fetch");
    assert.doesNotMatch(source, /https?:\/\//, relativePath + " contains remote URL");
  });
});

test("作品データはゲーム処理ファイルから分離されている", function () {
  const html = read("index.html");
  const data = read("data/game-data.js");
  const core = read("assets/js/core.js");

  assert.match(html, /data\/game-data\.js/);
  assert.match(data, /NHG_GAME_DATA/);
  assert.doesNotMatch(core, /sample-alpha|調査条件 A|自然史遊戯録/);
});

test("確認用作品データのIDと結果参照が整合する", function () {
  delete global.NHG_GAME_DATA;
  require("../data/game-data.js");
  const data = global.NHG_GAME_DATA;
  const specimenIds = new Set(data.specimens.map(function (item) { return item.id; }));
  const conditionIds = data.conditions.map(function (item) { return item.id; });

  assert.equal(typeof data.meta.titleId, "string");
  assert.equal(new Set(conditionIds).size, conditionIds.length);
  assert.equal(specimenIds.size, data.specimens.length);

  conditionIds.forEach(function (conditionId) {
    for (let actionCount = 0; actionCount < 6; actionCount += 1) {
      assert.equal(specimenIds.has(data.resolveResult(conditionId, actionCount)), true);
    }
  });
});
