(function (root) {
  "use strict";

  root.NHG_GAME_DATA = {
    meta: {
      titleId: "natural-history-game-template",
      title: "自然史遊戯録・短編共通基盤",
      subtitle: "作品データ差し替え前の動作確認版",
      gameVersion: "0.1.0",
      storageKey: "nhg:natural-history-game-template:save"
    },
    hub: {
      heading: "調査拠点",
      description: "行動条件を選び、標本記録を集めます。"
    },
    conditions: [
      {
        id: "survey-alpha",
        name: "調査条件 A",
        description: "作品固有ルールへ置き換えるための確認用条件です。"
      },
      {
        id: "survey-beta",
        name: "調査条件 B",
        description: "別条件でも同じ画面遷移と保存を確認できます。"
      }
    ],
    specimens: [
      {
        id: "sample-alpha",
        name: "確認用標本 A",
        summary: "作品固有の生物データを入れる前の仮標本です。"
      },
      {
        id: "sample-beta",
        name: "確認用標本 B",
        summary: "図鑑、重複記録、エンディング解放の確認に使います。"
      }
    ],
    ending: {
      threshold: 2,
      heading: "調査記録がまとまりました",
      body: "共通基盤の一連の画面遷移を完走しました。作品版では固有の結末へ差し替えます。"
    },
    resolveResult: function (conditionId, actionCount) {
      if (conditionId === "survey-beta") {
        return actionCount % 2 === 0 ? "sample-beta" : "sample-alpha";
      }
      return actionCount % 2 === 0 ? "sample-alpha" : "sample-beta";
    }
  };
})(typeof globalThis !== "undefined" ? globalThis : this);
