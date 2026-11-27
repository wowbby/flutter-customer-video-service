const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const ts = require(process.env.CUSTOMER_RTC_TYPESCRIPT || '/Applications/DevEco-Studio.app/Contents/tools/arktsdoc/node_modules/typescript');
const source = path.resolve(__dirname, '../src/main/ets/components/plugin/CleanupPolicy.ets');
const compiled = ts.transpileModule(fs.readFileSync(source, 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
}).outputText;
const mod = { exports: {} };
new Function('exports', 'module', compiled)(mod.exports, mod);
const { CleanupPolicy } = mod.exports;

(async () => {
  const clean = new CleanupPolicy();
  clean.stop(() => 0);
  assert.equal(await clean.destroy(async () => {}), 'released');
  const warnings = new CleanupPolicy();
  let calls = 0;
  warnings.stop(() => { calls++; return -7; });
  warnings.stop(() => { calls++; throw new Error('private SDK text'); });
  warnings.stop(() => { calls++; return 0; });
  let complete;
  let resolved = false;
  const pending = warnings.destroy(() => new Promise(resolve => { complete = resolve; calls++; }));
  pending.then(() => { resolved = true; });
  await Promise.resolve();
  assert.equal(resolved, false, 'release waits for async native destroy');
  complete();
  assert.equal(await pending, 'releasedWithWarnings');
  assert.equal(calls, 4, 'intermediate failures cannot skip later cleanup or destroy');
  const failed = new CleanupPolicy();
  await assert.rejects(failed.destroy(async () => { throw new Error('private destroy text'); }));
  console.log('PASS: release, intermediate failures, pending/rejected async destroy');
})().catch(error => { console.error(error); process.exitCode = 1; });
