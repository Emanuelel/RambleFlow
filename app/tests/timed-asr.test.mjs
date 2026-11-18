import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { timedAsr } from '../timed-asr.mjs';

test('speech sidecar imports leave signed resources unchanged', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'rambleflow-sidecar-'));
  let recognizer;
  try {
    await writeFile(join(directory, 'asr_terms.py'), `S_CONT = 4.0
BUDGET = 6.0
`);
    const server = join(directory, 'server.py');
    await writeFile(server, [
      'import json, sys',
      'import asr_terms',
      'assert asr_terms.S_CONT == 8.0',
      'assert asr_terms.BUDGET == 8.0',
      'print(json.dumps({"type": "ready"}), flush=True)',
      'for line in sys.stdin:',
      '    request = json.loads(line)',
      '    if request["cmd"] == "stream_finish":',
      '        print(json.dumps({"type": "result", "id": request["id"], "partial": False, "text": "Recognized audio"}), flush=True)',
    ].join(String.fromCharCode(10)));
    recognizer = timedAsr('python3', server, directory, () => {});
    await recognizer.ready;
    recognizer.start('test', ['Saved term']);
    assert.equal(await recognizer.finish('test'), 'Recognized audio');
    assert.deepEqual((await readdir(directory)).sort(), ['asr_terms.py', 'server.py']);
  } finally {
    recognizer?.close();
    await rm(directory, { recursive: true, force: true });
  }
});
