import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { downloadFiles, missingFiles, removeDamaged, timedSpeechModel } from '../model-download.mjs';

const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const file = (name, bytes) => ({ name, size: bytes.length, sha256: sha256(bytes), url: `https://example.test/${name}` });
// Serves the given bodies in two chunks each, like a network response.
const serve = bodies => async url => {
  const body = bodies[new URL(url).pathname.slice(1)];
  if (!body) return new Response(null, { status: 404 });
  return new Response(new ReadableStream({ start(controller) {
    controller.enqueue(body.subarray(0, 3)); controller.enqueue(body.subarray(3)); controller.close();
  } }));
};

test('downloads each file, checks it and reports progress across all of them', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'rambleflow-download-'));
  try {
    const first = Buffer.from('first model'), second = Buffer.from('second');
    const files = [file('a.bin', first), file('b.bin', second)];
    assert.deepEqual((await missingFiles(directory, files)).map(item => item.name), ['a.bin', 'b.bin']);
    const reports = [];
    await downloadFiles(directory, files, (done, total) => reports.push([done, total]), serve({ 'a.bin': first, 'b.bin': second }));
    assert.deepEqual(await readFile(join(directory, 'a.bin')), first);
    assert.deepEqual(await readFile(join(directory, 'b.bin')), second);
    assert.deepEqual(reports.at(-1), [17, 17]);
    assert.ok(reports.every(([done], index) => index === 0 || done >= reports[index - 1][0]));
    assert.deepEqual(await missingFiles(directory, files), []);
    assert.deepEqual((await readdir(directory)).sort(), ['a.bin', 'b.bin']);
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test('a wrong checksum, a failed request or a cut-off body leaves nothing behind', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'rambleflow-download-'));
  try {
    const expected = Buffer.from('expected bytes');
    const tampered = Buffer.from('tampered bytes');
    await assert.rejects(downloadFiles(directory, [file('a.bin', expected)], () => {}, serve({ 'a.bin': tampered })), /checksum/);
    await assert.rejects(downloadFiles(directory, [file('a.bin', expected)], () => {}, serve({})), /HTTP 404/);
    await assert.rejects(downloadFiles(directory, [file('a.bin', expected)], () => {}, serve({ 'a.bin': expected.subarray(0, 5) })), /checksum/);
    assert.deepEqual(await readdir(directory), []);
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test('a file of the wrong size counts as missing', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'rambleflow-download-'));
  try {
    const bytes = Buffer.from('complete');
    await writeFile(join(directory, 'a.bin'), bytes.subarray(0, 4));
    assert.equal((await missingFiles(directory, [file('a.bin', bytes)])).length, 1);
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test('a damaged file of the right size is removed so it downloads again', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'rambleflow-download-'));
  try {
    const good = Buffer.from('good bytes'), other = Buffer.from('fine');
    const files = [file('a.bin', good), file('b.bin', other)];
    await writeFile(join(directory, 'a.bin'), Buffer.from('BAD! bytes'));
    await writeFile(join(directory, 'b.bin'), other);
    assert.deepEqual((await removeDamaged(directory, files)).map(item => item.name), ['a.bin']);
    assert.deepEqual((await missingFiles(directory, files)).map(item => item.name), ['a.bin']);
    assert.deepEqual(await readdir(directory), ['b.bin']);
  } finally { await rm(directory, { recursive: true, force: true }); }
});

test('the timed speech model is pinned to one commit with a hash for every file', () => {
  assert.ok(timedSpeechModel.files.every(item => /^[0-9a-f]{64}$/.test(item.sha256) && item.size > 0 &&
    item.url.startsWith('https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v2/resolve/8ae155301e23d820d82aa60d24817c900e69e487/')));
  assert.equal(timedSpeechModel.files.reduce((sum, item) => sum + item.size, 0), 2_471_863_880);
});
