(function (root) {
  "use strict";

  const core = root.NHGCore;
  const gameData = root.NHG_GAME_DATA;

  if (!core || !gameData) {
    document.body.textContent = "ゲーム基盤または作品データを読み込めませんでした。";
    return;
  }

  const byId = function (id) { return document.getElementById(id); };
  const screens = Array.from(document.querySelectorAll("[data-screen]"));
  const specimenById = new Map(gameData.specimens.map(function (item) { return [item.id, item]; }));
  const conditionById = new Map(gameData.conditions.map(function (item) { return [item.id, item]; }));
  let state;
  let recovery = null;
  let memoryOnly = false;
  let statusTimer = null;

  function status(message, kind) {
    const element = byId("status-message");
    element.textContent = message;
    element.dataset.kind = kind || "info";
    element.hidden = false;
    root.clearTimeout(statusTimer);
    statusTimer = root.setTimeout(function () {
      element.hidden = true;
    }, 4500);
  }

  function guard(handler) {
    return function (event) {
      try {
        handler(event);
      } catch (error) {
        status(error && error.message ? error.message : "処理に失敗しました。", "error");
      }
    };
  }

  function downloadText(filename, text, mimeType) {
    const blob = new Blob([text], { type: mimeType || "application/json" });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = filename;
    document.body.appendChild(anchor);
    anchor.click();
    anchor.remove();
    root.setTimeout(function () { URL.revokeObjectURL(url); }, 0);
  }

  function save(message) {
    if (recovery || memoryOnly) {
      if (message && memoryOnly) {
        status(message + "（この確認中は保存されません）", "warning");
      }
      return;
    }

    try {
      state = core.saveState(root.localStorage, gameData, state);
      if (message) {
        status(message, "success");
      }
    } catch (error) {
      memoryOnly = true;
      status("保存できないため、保存なしで続行します。", "warning");
    }
  }

  function safeResumeScreen() {
    const requested = state.progress.screen;

    if (requested === "result" && !specimenById.has(state.progress.lastResultId)) {
      return "hub";
    }
    if (requested === "condition" && state.progress.selectedConditionId && !conditionById.has(state.progress.selectedConditionId)) {
      return "hub";
    }
    if (requested === "ending" && !state.progress.endingUnlocked) {
      return "hub";
    }
    return core.SCREEN_IDS.includes(requested) ? requested : "title";
  }

  function showScreen(screenId, options) {
    const settings = options || {};
    if (!core.SCREEN_IDS.includes(screenId)) {
      screenId = "title";
    }
    if (screenId === "ending" && !state.progress.endingUnlocked) {
      screenId = "hub";
    }

    screens.forEach(function (screen) {
      const active = screen.dataset.screen === screenId;
      screen.hidden = !active;
      screen.classList.toggle("is-active", active);
    });

    state = core.setScreen(state, screenId);
    render();

    if (settings.persist) {
      save();
    }

    byId("app-main").focus({ preventScroll: true });
    root.scrollTo(0, 0);
  }

  function renderConditions() {
    const list = byId("condition-list");
    list.replaceChildren();

    gameData.conditions.forEach(function (condition, index) {
      const label = document.createElement("label");
      label.className = "choice-card";

      const input = document.createElement("input");
      input.type = "radio";
      input.name = "condition";
      input.value = condition.id;
      input.required = true;
      input.checked = state.progress.selectedConditionId
        ? state.progress.selectedConditionId === condition.id
        : index === 0;

      const text = document.createElement("span");
      const strong = document.createElement("strong");
      const description = document.createElement("small");
      strong.textContent = condition.name;
      description.textContent = condition.description;
      text.append(strong, description);
      label.append(input, text);
      list.appendChild(label);
    });
  }

  function renderCollection() {
    const list = byId("collection-list");
    list.replaceChildren();
    const ids = Object.keys(state.collection).sort(function (left, right) {
      return state.collection[left].discoveredAt.localeCompare(state.collection[right].discoveredAt);
    });

    if (ids.length === 0) {
      const empty = document.createElement("p");
      empty.className = "empty-state";
      empty.textContent = "まだ標本はありません。行動条件を選んで調査してください。";
      list.appendChild(empty);
      return;
    }

    ids.forEach(function (id) {
      const record = state.collection[id];
      const specimen = specimenById.get(id);
      const card = document.createElement("article");
      card.className = "collection-card";

      const mark = document.createElement("span");
      mark.className = "collection-mark";
      mark.setAttribute("aria-hidden", "true");
      mark.textContent = "◇";

      const body = document.createElement("div");
      const heading = document.createElement("h2");
      const summary = document.createElement("p");
      const count = document.createElement("small");
      heading.textContent = specimen ? specimen.name : "未登録の標本（" + id + "）";
      summary.textContent = specimen ? specimen.summary : "作品データに存在しない記録です。記録自体は失わず保持します。";
      count.textContent = "記録回数: " + record.count;
      body.append(heading, summary, count);
      card.append(mark, body);
      list.appendChild(card);
    });
  }

  function renderResult() {
    const id = state.progress.lastResultId;
    const specimen = specimenById.get(id);
    if (!specimen) {
      byId("result-name").textContent = "調査記録なし";
      byId("result-summary").textContent = "新しい調査を実行してください。";
      byId("result-count").textContent = "";
      return;
    }

    byId("result-name").textContent = specimen.name;
    byId("result-summary").textContent = specimen.summary;
    byId("result-count").textContent = "この標本の記録回数: " + state.collection[id].count;
  }

  function render() {
    document.title = gameData.meta.title;
    byId("header-title").textContent = gameData.meta.title;
    byId("title-heading").textContent = gameData.meta.title;
    byId("title-subtitle").textContent = gameData.meta.subtitle;
    byId("hub-heading").textContent = gameData.hub.heading;
    byId("hub-description").textContent = gameData.hub.description;
    byId("action-count").textContent = String(state.progress.actionCount);
    byId("collection-count").textContent = String(Object.keys(state.collection).length);
    byId("open-ending").disabled = !state.progress.endingUnlocked;
    byId("ending-heading").textContent = gameData.ending.heading;
    byId("ending-body").textContent = gameData.ending.body;
    byId("volume").value = String(state.settings.volume);
    byId("volume-output").textContent = Math.round(state.settings.volume * 100) + "%";
    byId("reduced-motion").checked = state.settings.reducedMotion;
    document.body.classList.toggle("reduce-motion", state.settings.reducedMotion);
    renderConditions();
    renderCollection();
    renderResult();
  }

  function setRecoveryMode(recoveryInfo) {
    recovery = recoveryInfo;
    const card = byId("recovery-card");
    card.hidden = false;
    byId("recovery-reason").textContent = recoveryInfo.reason;
    byId("download-broken-save").hidden = typeof recoveryInfo.raw !== "string";
    document.querySelectorAll("[data-requires-storage]").forEach(function (button) {
      button.disabled = true;
    });
  }

  function clearRecoveryMode() {
    recovery = null;
    byId("recovery-card").hidden = true;
    document.querySelectorAll("[data-requires-storage]").forEach(function (button) {
      button.disabled = false;
    });
  }

  function initialize() {
    const loaded = core.loadState(root.localStorage, gameData);
    state = loaded.state;
    if (loaded.recovery) {
      setRecoveryMode(loaded.recovery);
      showScreen("title");
    } else {
      const resume = safeResumeScreen();
      if (resume !== state.progress.screen) {
        state = core.setScreen(state, resume);
        save();
      }
      showScreen(resume);
    }
  }

  document.querySelectorAll("[data-go]").forEach(function (button) {
    button.addEventListener("click", guard(function () {
      const destination = button.dataset.go;
      if (destination === "condition" && !state.progress.selectedConditionId && gameData.conditions[0]) {
        state = core.selectCondition(state, gameData.conditions[0].id);
      }
      showScreen(destination);
    }));
  });

  byId("start-game").addEventListener("click", guard(function () {
    showScreen("hub", { persist: true });
  }));

  byId("open-settings").addEventListener("click", guard(function () {
    showScreen("settings-record");
  }));

  byId("open-condition").addEventListener("click", guard(function () {
    if (!state.progress.selectedConditionId && gameData.conditions[0]) {
      state = core.selectCondition(state, gameData.conditions[0].id);
    }
    showScreen("condition");
  }));

  byId("open-ending").addEventListener("click", guard(function () {
    showScreen("ending", { persist: true });
  }));

  byId("condition-form").addEventListener("submit", guard(function (event) {
    event.preventDefault();
    const formData = new FormData(event.currentTarget);
    const conditionId = formData.get("condition");
    if (typeof conditionId !== "string" || !conditionById.has(conditionId)) {
      throw new Error("調査条件を選んでください。");
    }

    state = core.selectCondition(state, conditionId);
    const resultId = gameData.resolveResult(conditionId, state.progress.actionCount);
    if (!specimenById.has(resultId)) {
      throw new Error("作品データが未登録の標本を返しました。");
    }
    state = core.addDiscovery(state, resultId, gameData.ending.threshold);
    save("調査結果を自動保存しました。");
    showScreen("result");
  }));

  byId("volume").addEventListener("change", guard(function (event) {
    state.settings.volume = Number(event.currentTarget.value);
    save("音量設定を保存しました。");
    render();
  }));

  byId("reduced-motion").addEventListener("change", guard(function (event) {
    state.settings.reducedMotion = event.currentTarget.checked;
    save("表示設定を保存しました。");
    render();
  }));

  byId("export-record").addEventListener("click", guard(function () {
    const record = core.createPortableRecord(state);
    state.exportedCollectionRecord = record;
    save();
    downloadText(gameData.meta.titleId + "-record.json", JSON.stringify(record, null, 2));
    status("記録JSONを書き出しました。", "success");
  }));

  byId("import-record").addEventListener("change", guard(function (event) {
    const input = event.currentTarget;
    const file = input.files && input.files[0];
    if (!file) {
      return;
    }
    if (file.size > 1024 * 1024) {
      input.value = "";
      throw new Error("記録JSONは1MB以下のファイルを選んでください。");
    }

    const reader = new FileReader();
    reader.addEventListener("load", guard(function () {
      let parsed;
      try {
        parsed = JSON.parse(String(reader.result));
      } catch (error) {
        throw new Error("記録JSONを解析できませんでした。");
      }

      const result = core.importRecord(state, parsed, gameData);
      if (!result.ok) {
        throw new Error(result.errors.join(" "));
      }
      state = result.state;
      save("記録を統合しました。既存の進捗は後退していません。");
      render();
      input.value = "";
    }));
    reader.addEventListener("error", function () {
      status("記録JSONを読み取れませんでした。", "error");
    });
    reader.readAsText(file, "utf-8");
  }));

  byId("download-broken-save").addEventListener("click", guard(function () {
    if (recovery && typeof recovery.raw === "string") {
      downloadText(gameData.meta.titleId + "-broken-save.txt", recovery.raw, "text/plain");
      status("元の保存データを退避しました。", "success");
    }
  }));

  byId("reset-save").addEventListener("click", guard(function () {
    state = core.resetState(root.localStorage, gameData);
    memoryOnly = false;
    clearRecoveryMode();
    showScreen("title");
    status("保存データを初期化しました。", "success");
  }));

  byId("continue-without-save").addEventListener("click", guard(function () {
    memoryOnly = true;
    clearRecoveryMode();
    showScreen("hub");
    status("保存なしの確認モードで開始しました。", "warning");
  }));

  byId("request-reset").addEventListener("click", guard(function () {
    if (!root.confirm("端末内の保存データを初期化します。書き出していない記録は失われます。よろしいですか？")) {
      return;
    }
    state = core.resetState(root.localStorage, gameData);
    memoryOnly = false;
    clearRecoveryMode();
    showScreen("title");
    status("保存データを初期化しました。", "success");
  }));

  root.addEventListener("error", function (event) {
    event.preventDefault();
    status("予期しないエラーを安全に停止しました。再操作するか、設定・記録を確認してください。", "error");
  });

  root.addEventListener("unhandledrejection", function (event) {
    event.preventDefault();
    status("処理を完了できませんでした。再操作してください。", "error");
  });

  initialize();
})(window);
