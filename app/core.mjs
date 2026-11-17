import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { access } from 'node:fs/promises';
import { isAbsolute } from 'node:path';

export const modes = new Set(['minimal', 'casual', 'formal', 'prompt']);
export function modeForApp(bundle = '') {
  if (/terminal|iterm|warp|code|codex|chatgpt|claude|gemini|xcode|cursor/i.test(bundle)) return 'prompt';
  if (/mail|outlook|superhuman|slack|teams|googlechat/i.test(bundle)) return 'formal';
  if (/messages|ichat|whatsapp|telegram|discord|twitter/i.test(bundle)) return 'casual';
  return 'minimal';
}
export function vocabularyTerms(value = []) {
  if (!Array.isArray(value) || value.length > 80) throw new Error('Vocabulary must contain at most 80 terms.');
  return [...new Set(value.map(term => {
    if (typeof term !== 'string' || !term.trim() || term.length > 100 || /[\r\n\x00-\x1f]/u.test(term)) throw new Error('Use one vocabulary term per line, up to 100 characters.');
    return term.trim();
  }))];
}
export async function checksum(path) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest('hex');
}
export async function validateConfig(config) {
  if (config.version !== 1) throw new Error('Config version must be 1.');
  for (const field of ['cacheDirectory', 'modelPath', 'adapterPath']) {
    const path = config[field];
    if (field === 'adapterPath' && !path) continue;
    // A caller can resolve the bundled default before validating its weights.
    if (field === 'modelPath' && path == null) {
      if (config.adapterPath) throw new Error('An adapter needs the modelPath it was trained on.');
      continue;
    }
    if (typeof path !== 'string' || !isAbsolute(path)) throw new Error(`${field} must be an absolute path.`);
    if (field !== 'cacheDirectory') await access(path);
  }
  for (const [pathKey, hashKey] of [['modelPath', 'modelSha256'], ['adapterPath', 'adapterSha256']]) {
    if (!config[pathKey]) continue;
    if (!/^[a-f0-9]{64}$/u.test(config[hashKey] ?? '')) throw new Error(`${hashKey} is required to identify the selected weights.`);
    if (await checksum(config[pathKey]) !== config[hashKey]) throw new Error(`${pathKey} checksum mismatch.`);
  }
  if (config.adapterPath && config.adapterBaseSha256 !== config.modelSha256) throw new Error('Adapter base checksum does not match the selected model.');
  vocabularyTerms(config.vocabulary);
  return config;
}
export function outputGuard(raw, output, stopReason, stats = {}, cap = 768, context = 4096) {
  const words = text => text.trim().split(/\s+/u).filter(Boolean);
  if (!output.trim()) return 'The refiner returned no text.';
  // Released QVAC uses an absent stopReason for normal completion.
  if (stopReason != null && stopReason !== 'eos') return 'The refiner did not finish normally.';
  if ((stats.generatedTokens ?? 0) >= cap) return 'The refiner reached its output limit.';
  if ((stats.promptTokens ?? 0) + (stats.generatedTokens ?? 0) >= context) return 'The refiner reached its context limit.';
  if (/<\|[^>]+\|>|<\/?think>/iu.test(output)) return 'The refiner returned internal markers.';
  if (words(output).length > Math.max(words(raw).length * 2, 8)) return 'The refiner expanded the dictation unexpectedly.';
  if (words(raw).length > 8 && words(output).length < words(raw).length * 0.4) return 'The refiner dropped too much text.';
  return null;
}
// With cleanup switched off the recognizer's text is the result, untouched by the refiner.
export function rawResult(raw) {
  return raw.trim() ? { raw, text: raw.trim() } : { raw: '', text: '', warning: 'No speech detected.' };
}
export function applySegment(segments, segment) {
  const before = segment.append ? segments.get(segment.id) ?? '' : '';
  const gap = before && segment.startsWord && !/\s$/u.test(before) && !/^\s/u.test(segment.text) ? ' ' : '';
  segments.set(segment.id, before + gap + segment.text);
  return [...segments.entries()].sort((a, b) => a[0] - b[0]).map(([, value]) => value).join(' ').trim();
}

export function joinRecognitionSegments(segments) {
  let joined = '';
  for (const segment of segments) {
    if (!joined) {
      joined = segment;
      continue;
    }
    const left = joined.match(/\b(and|or|but|so|who|is)$/i);
    const right = segment.match(/^(and|or|but|so|who|is)\s+/i);
    const repeated = left && right && left[1].toLowerCase() === right[1].toLowerCase();
    joined += ' ' + (repeated ? segment.slice(right[0].length) : segment);
  }
  return joined;
}
