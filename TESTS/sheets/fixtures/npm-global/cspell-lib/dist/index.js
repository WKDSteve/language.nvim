// Stand-in for cspell-lib in the feature sheet language.spell-cspell-sidecar: the three functions
// node/cspell_server.js calls, flagging a fixed word list. The sidecar process itself (node) is real.
// It flags "reply", a correct word on purpose: the native check (which always runs as well) passes it, so a
// finding of it can only have come through the sidecar.
const MISSPELLED = { reply: ["answer"] };

export async function getDefaultSettings() {
  return {};
}

export function mergeSettings(base, extra) {
  return Object.assign({}, base, extra);
}

export async function spellCheckDocument(doc, options) {
  const issues = [];
  const text = doc.text || "";
  const words = /[A-Za-z]+/g;
  let m;
  while ((m = words.exec(text)) !== null) {
    const fixes = MISSPELLED[m[0].toLowerCase()];
    if (fixes) {
      issues.push({
        offset: m.index,
        text: m[0],
        suggestions: options && options.generateSuggestions ? fixes : [],
      });
    }
  }
  return { issues };
}
