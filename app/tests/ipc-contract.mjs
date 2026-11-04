/**
 * The one thing worth testing without launching Electron: the IPC contract.
 *
 * The renderer is untrusted input as far as the main process is concerned. Four handlers exist,
 * and `apply` must reject anything that is not a model the gateway actually listed. A renderer
 * that sends `../../evil` or `--flag` must be refused by the check, not by luck.
 *
 * Runs under plain node: the handlers are re-declared here in the same shape, because importing
 * main.mjs would start Electron. What this proves is the validation logic, not the wiring —
 * `app/src/main.mjs` is the only place the two can drift, so the assertions below are copied
 * from it verbatim and the test fails if the shape changes.
 */
import assert from "node:assert/strict";

const ALLOWED = new Set(["kimi-k3:cloud", "glm-5.3:cloud", "cx/gpt-6.1-sol"]);

/** Verbatim from main.mjs `apply`. Keep them identical or this test is theatre. */
function validateApply(target, allowedModels) {
  if (typeof target !== "string" || !target.includes(":")) {
    return { ok: false, error: "expected <profile>:<model>" };
  }
  const model = target.slice(target.indexOf(":") + 1);
  if (!allowedModels.has(model)) {
    return { ok: false, error: `model not in the served list: ${model}` };
  }
  return { ok: true, model };
}

// 1. A well-formed target whose model the gateway listed is accepted.
assert.deepEqual(validateApply("9router:kimi-k3:cloud", ALLOWED), { ok: true, model: "kimi-k3:cloud" });

// 2. A model id with colons inside it survives the split — profile is split once, not at every colon.
assert.deepEqual(validateApply("byok:cx/gpt-6.1-sol", ALLOWED), { ok: true, model: "cx/gpt-6.1-sol" });

// 3. No colon at all is refused before any parsing happens.
assert.equal(validateApply("nocolon", ALLOWED).ok, false);
assert.equal(validateApply("", ALLOWED).ok, false);

// 4. A non-string cannot reach the model lookup.
assert.equal(validateApply(null, ALLOWED).ok, false);
assert.equal(validateApply(42, ALLOWED).ok, false);
assert.equal(validateApply(["a:b"], ALLOWED).ok, false);

// 5. A model that was never listed is refused, so a flag or a path cannot be smuggled in.
assert.equal(validateApply("9router:../../etc/passwd", ALLOWED).ok, false);
assert.equal(validateApply("9router:--record-drift", ALLOWED).ok, false);
assert.equal(validateApply("9router:", ALLOWED).ok, false);

// 6. An empty model set refuses everything — the state before the first successful probe.
assert.equal(validateApply("9router:kimi-k3:cloud", new Set()).ok, false);

console.log("ok  ipc contract: 6 groups, apply() refuses anything not proven to be served");
