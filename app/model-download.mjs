import { createHash } from 'node:crypto';
import { createReadStream, createWriteStream } from 'node:fs';
import { mkdir, rename, rm, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { Readable, Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';

// The timed recognizer's speech model: MLX Community's conversion of NVIDIA Parakeet TDT 0.6B v2,
// pinned to the tested commit. Too large for a GitHub release file, so it downloads on first launch.
const parakeetCommit = '8ae155301e23d820d82aa60d24817c900e69e487';
const parakeetBase = `https://huggingface.co/mlx-community/parakeet-tdt-0.6b-v2/resolve/${parakeetCommit}/`;
export const timedSpeechModel = {
  directory: 'parakeet-tdt-0.6b-v2-mlx-8ae1553',
  files: [
    ['model.safetensors', 2471559904, 'b958c37a6baa6874a279108755c8f2818e27bf647d72d54800a234a421341dfe'],
    ['config.json', 36176, '9bd323e60afe2615c983a5d9fc3a2c0470df2a03edf90c0f861bd59509d07264'],
    ['tokenizer.model', 251396, '5a3a82c48998709f9bc9f5db2924d99a899d20bf82550ca52272da7c7557b0a0'],
    ['tokenizer.vocab', 10393, 'dbe7ec6bd066c4526080940e1614e6582b9161515e856c2c39a1d49267c88cbc'],
    ['vocab.txt', 5066, '70b25deed256d79365a3c290d6191c31cc2315d952faf18d5c3a334f46e4866e'],
    ['README.md', 945, 'af484ebbab54ee50ccfa4f07e778c0f7b2f05a0ac6a2d138e5aee5aae1366f9b'],
  ].map(([name, size, sha256]) => ({ name, size, sha256, url: parakeetBase + name })),
};

// Files that are absent or the wrong size. Each file's hash was checked when it was downloaded,
// so a later launch only compares sizes instead of reading gigabytes again.
export async function missingFiles(directory, files) {
  const missing = [];
  for (const file of files) {
    try {
      if ((await stat(join(directory, file.name))).size === file.size) continue;
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
    missing.push(file);
  }
  return missing;
}

// Present files whose content no longer matches their hash. They are deleted, so the next check counts
// them as missing and downloads them again.
export async function removeDamaged(directory, files) {
  const damaged = [];
  for (const file of files) {
    const path = join(directory, file.name);
    const hash = createHash('sha256');
    try {
      for await (const chunk of createReadStream(path)) hash.update(chunk);
    } catch (error) {
      if (error.code === 'ENOENT') continue;
      throw error;
    }
    if (hash.digest('hex') === file.sha256) continue;
    await rm(path, { force: true });
    damaged.push(file);
  }
  return damaged;
}

// Downloads each file to a temporary name, checks its size and SHA-256, then moves it into place,
// so an interrupted download is never mistaken for a complete one. Reports bytes across all files.
export async function downloadFiles(directory, files, onProgress = () => {}, fetchImpl = fetch) {
  await mkdir(directory, { recursive: true });
  const total = files.reduce((sum, file) => sum + file.size, 0);
  let done = 0;
  for (const file of files) {
    const partial = join(directory, file.name + '.part');
    await rm(partial, { force: true });
    try {
      const response = await fetchImpl(file.url);
      if (!response.ok || !response.body) throw new Error(`Download of ${file.name} failed with HTTP ${response.status}.`);
      const hash = createHash('sha256');
      let received = 0;
      const count = new Transform({
        transform(chunk, _encoding, callback) {
          hash.update(chunk);
          received += chunk.length;
          if (received > file.size) return callback(new Error(`Download of ${file.name} is larger than expected.`));
          onProgress(done + received, total);
          callback(null, chunk);
        },
      });
      await pipeline(Readable.fromWeb(response.body), count, createWriteStream(partial, { mode: 0o644 }));
      if (received !== file.size || hash.digest('hex') !== file.sha256) throw new Error(`Download of ${file.name} did not match its expected checksum.`);
      await rename(partial, join(directory, file.name));
      done += file.size;
    } catch (error) {
      await rm(partial, { force: true });
      throw error;
    }
  }
  onProgress(total, total);
}
