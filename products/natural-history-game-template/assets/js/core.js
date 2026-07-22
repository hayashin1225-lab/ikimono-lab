(function (root, factory) {
  "use strict";

  const api = factory();

  if (typeof module === "object" && module.exports) {
    module.exports = api;
  }

  if (root) {
    root.NHGCore = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  const SCHEMA_VERSION = 1;
  const PORTABLE_RECORD_TYPE = "natural-history-game-collection-record";
  const SCREEN_IDS = [
    "title",
    "hub",
    "condition",
    "result",
    "collection",
    "ending",
    "settings-record"
  ];

  function isoNow(now) {
    const value = now instanceof Date ? now : new Date(now || Date.now());
    return value.toISOString();
  }

  function clone(value) {
    return JSON.parse(JSON.stringify(value));
  }

  function isPlainObject(value) {
    return Boolean(value) && typeof value === "object" && !Array.isArray(value);
  }

  function isSafeId(value) {
    return typeof value === "string"
      && /^[a-z0-9][a-z0-9._:-]{0,127}$/i.test(value)
      && value !== "__proto__"
      && value !== "prototype"
      && value !== "constructor";
  }

  function uniqueStrings(values) {
    if (!Array.isArray(values)) {
      return [];
    }

    return Array.from(
      new Set(values.filter(function (value) {
        return typeof value === "string" && value.length > 0;
      }))
    ).sort();
  }

  function requiredMeta(gameData) {
    if (!gameData || !gameData.meta) {
      throw new Error("作品データの meta がありません。");
    }

    ["titleId", "gameVersion", "storageKey"].forEach(function (key) {
      if (typeof gameData.meta[key] !== "string" || gameData.meta[key].length === 0) {
        throw new Error("作品データの meta." + key + " が不正です。");
      }
    });

    return gameData.meta;
  }

  function createInitialState(gameData, now) {
    const meta = requiredMeta(gameData);
    const timestamp = isoNow(now);

    return {
      schemaVersion: SCHEMA_VERSION,
      titleId: meta.titleId,
      gameVersion: meta.gameVersion,
      createdAt: timestamp,
      updatedAt: timestamp,
      progress: {
        screen: "title",
        actionCount: 0,
        endingUnlocked: false,
        lastResultId: null,
        selectedConditionId: null
      },
      collection: {},
      achievements: [],
      settings: {
        volume: 0.7,
        reducedMotion: false
      },
      exportedCollectionRecord: null
    };
  }

  function validateCollection(collection, errors) {
    if (!isPlainObject(collection)) {
      errors.push("collection はオブジェクトである必要があります。");
      return;
    }

    Object.keys(collection).forEach(function (id) {
      const entry = collection[id];
      if (!isSafeId(id)) {
        errors.push("collection のIDが不正です。");
        return;
      }
      if (!isPlainObject(entry) || entry.id !== id) {
        errors.push("collection." + id + " の形式が不正です。");
        return;
      }
      if (!Number.isInteger(entry.count) || entry.count < 1) {
        errors.push("collection." + id + ".count が不正です。");
      }
      if (typeof entry.discoveredAt !== "string") {
        errors.push("collection." + id + ".discoveredAt が不正です。");
      }
    });
  }

  function validateState(candidate, gameData) {
    const meta = requiredMeta(gameData);
    const errors = [];

    if (!isPlainObject(candidate)) {
      return { ok: false, errors: ["保存データがオブジェクトではありません。"] };
    }

    if (candidate.schemaVersion !== SCHEMA_VERSION) {
      errors.push("schemaVersion に対応していません。");
    }
    if (candidate.titleId !== meta.titleId) {
      errors.push("別作品の保存データです。");
    }
    if (typeof candidate.gameVersion !== "string") {
      errors.push("gameVersion が不正です。");
    }
    if (typeof candidate.createdAt !== "string" || typeof candidate.updatedAt !== "string") {
      errors.push("保存日時が不正です。");
    }

    if (!isPlainObject(candidate.progress)) {
      errors.push("progress が不正です。");
    } else {
      if (!SCREEN_IDS.includes(candidate.progress.screen)) {
        errors.push("progress.screen が不正です。");
      }
      if (!Number.isInteger(candidate.progress.actionCount) || candidate.progress.actionCount < 0) {
        errors.push("progress.actionCount が不正です。");
      }
      if (typeof candidate.progress.endingUnlocked !== "boolean") {
        errors.push("progress.endingUnlocked が不正です。");
      }
    }

    validateCollection(candidate.collection, errors);

    if (!Array.isArray(candidate.achievements)) {
      errors.push("achievements が配列ではありません。");
    }

    if (!isPlainObject(candidate.settings)) {
      errors.push("settings が不正です。");
    } else {
      if (typeof candidate.settings.volume !== "number" || candidate.settings.volume < 0 || candidate.settings.volume > 1) {
        errors.push("settings.volume が不正です。");
      }
      if (typeof candidate.settings.reducedMotion !== "boolean") {
        errors.push("settings.reducedMotion が不正です。");
      }
    }

    if (!(candidate.exportedCollectionRecord === null || isPlainObject(candidate.exportedCollectionRecord))) {
      errors.push("exportedCollectionRecord が不正です。");
    }

    return { ok: errors.length === 0, errors: errors };
  }

  function loadState(storage, gameData, now) {
    const meta = requiredMeta(gameData);
    let raw;

    try {
      raw = storage.getItem(meta.storageKey);
    } catch (error) {
      return {
        state: createInitialState(gameData, now),
        recovery: {
          reason: "保存領域を読み取れませんでした。",
          raw: null,
          detail: String(error && error.message ? error.message : error)
        }
      };
    }

    if (raw === null) {
      return { state: createInitialState(gameData, now), recovery: null };
    }

    try {
      const parsed = JSON.parse(raw);
      const validation = validateState(parsed, gameData);
      if (!validation.ok) {
        return {
          state: createInitialState(gameData, now),
          recovery: { reason: validation.errors.join(" "), raw: raw, detail: null }
        };
      }
      return { state: parsed, recovery: null };
    } catch (error) {
      return {
        state: createInitialState(gameData, now),
        recovery: {
          reason: "保存データを解析できませんでした。",
          raw: raw,
          detail: String(error && error.message ? error.message : error)
        }
      };
    }
  }

  function saveState(storage, gameData, state, now) {
    const meta = requiredMeta(gameData);
    const next = clone(state);
    next.updatedAt = isoNow(now);
    next.gameVersion = meta.gameVersion;

    const validation = validateState(next, gameData);
    if (!validation.ok) {
      throw new Error("保存データを作成できません: " + validation.errors.join(" "));
    }

    storage.setItem(meta.storageKey, JSON.stringify(next));
    return next;
  }

  function resetState(storage, gameData, now) {
    const meta = requiredMeta(gameData);
    storage.removeItem(meta.storageKey);
    return saveState(storage, gameData, createInitialState(gameData, now), now);
  }

  function setScreen(state, screenId) {
    if (!SCREEN_IDS.includes(screenId)) {
      throw new Error("未定義の画面です: " + screenId);
    }
    const next = clone(state);
    next.progress.screen = screenId;
    return next;
  }

  function selectCondition(state, conditionId) {
    const next = clone(state);
    next.progress.selectedConditionId = conditionId;
    next.progress.screen = "condition";
    return next;
  }

  function addDiscovery(state, specimenId, endingThreshold, now) {
    const next = clone(state);
    const timestamp = isoNow(now);
    const previous = next.collection[specimenId];

    next.collection[specimenId] = previous
      ? {
          id: specimenId,
          count: previous.count + 1,
          discoveredAt: previous.discoveredAt,
          lastDiscoveredAt: timestamp
        }
      : {
          id: specimenId,
          count: 1,
          discoveredAt: timestamp,
          lastDiscoveredAt: timestamp
        };

    next.progress.actionCount += 1;
    next.progress.lastResultId = specimenId;
    next.progress.screen = "result";

    if (Object.keys(next.collection).length >= endingThreshold) {
      next.progress.endingUnlocked = true;
      next.achievements = uniqueStrings(next.achievements.concat(["first-ending-unlocked"]));
    }

    return next;
  }

  function createPortableRecord(state, now) {
    return {
      recordType: PORTABLE_RECORD_TYPE,
      schemaVersion: SCHEMA_VERSION,
      titleId: state.titleId,
      gameVersion: state.gameVersion,
      exportedAt: isoNow(now),
      progress: {
        actionCount: state.progress.actionCount,
        endingUnlocked: state.progress.endingUnlocked
      },
      collection: clone(state.collection),
      achievements: uniqueStrings(state.achievements)
    };
  }

  function normalizeImportedRecord(candidate, gameData) {
    const meta = requiredMeta(gameData);
    const source = candidate && candidate.recordType === PORTABLE_RECORD_TYPE
      ? candidate
      : candidate;
    const errors = [];

    if (!isPlainObject(source)) {
      return { ok: false, errors: ["記録JSONがオブジェクトではありません。"] };
    }
    if (source.schemaVersion !== SCHEMA_VERSION) {
      errors.push("対応していない記録形式です。");
    }
    if (source.titleId !== meta.titleId) {
      errors.push("別作品の記録です。");
    }
    if (!isPlainObject(source.progress)) {
      errors.push("progress がありません。");
    }

    validateCollection(source.collection, errors);

    if (!Array.isArray(source.achievements)) {
      errors.push("achievements がありません。");
    }

    if (errors.length > 0) {
      return { ok: false, errors: errors };
    }

    const actionCount = Number.isInteger(source.progress.actionCount) && source.progress.actionCount >= 0
      ? source.progress.actionCount
      : 0;

    return {
      ok: true,
      record: {
        recordType: PORTABLE_RECORD_TYPE,
        schemaVersion: SCHEMA_VERSION,
        titleId: meta.titleId,
        gameVersion: typeof source.gameVersion === "string" ? source.gameVersion : meta.gameVersion,
        exportedAt: typeof source.exportedAt === "string" ? source.exportedAt : null,
        progress: {
          actionCount: actionCount,
          endingUnlocked: Boolean(source.progress.endingUnlocked)
        },
        collection: clone(source.collection),
        achievements: uniqueStrings(source.achievements)
      }
    };
  }

  function mergeCollection(current, imported) {
    const merged = clone(current);

    Object.keys(imported).forEach(function (id) {
      const incoming = imported[id];
      const existing = merged[id];

      if (!existing) {
        merged[id] = clone(incoming);
        return;
      }

      const discoveredAt = [existing.discoveredAt, incoming.discoveredAt]
        .filter(Boolean)
        .sort()[0];
      const lastDiscoveredAt = [existing.lastDiscoveredAt, incoming.lastDiscoveredAt]
        .filter(Boolean)
        .sort()
        .slice(-1)[0] || discoveredAt;

      merged[id] = {
        id: id,
        count: Math.max(existing.count, incoming.count),
        discoveredAt: discoveredAt,
        lastDiscoveredAt: lastDiscoveredAt
      };
    });

    return merged;
  }

  function importRecord(state, candidate, gameData) {
    const normalized = normalizeImportedRecord(candidate, gameData);
    if (!normalized.ok) {
      return normalized;
    }

    const record = normalized.record;
    const next = clone(state);
    next.collection = mergeCollection(next.collection, record.collection);
    next.progress.actionCount = Math.max(next.progress.actionCount, record.progress.actionCount);
    next.progress.endingUnlocked = next.progress.endingUnlocked || record.progress.endingUnlocked;
    next.achievements = uniqueStrings(next.achievements.concat(record.achievements));
    next.exportedCollectionRecord = clone(record);

    return { ok: true, state: next, record: record };
  }

  return {
    SCHEMA_VERSION: SCHEMA_VERSION,
    PORTABLE_RECORD_TYPE: PORTABLE_RECORD_TYPE,
    SCREEN_IDS: SCREEN_IDS.slice(),
    addDiscovery: addDiscovery,
    createInitialState: createInitialState,
    createPortableRecord: createPortableRecord,
    importRecord: importRecord,
    isSafeId: isSafeId,
    loadState: loadState,
    resetState: resetState,
    saveState: saveState,
    selectCondition: selectCondition,
    setScreen: setScreen,
    validateState: validateState
  };
});
