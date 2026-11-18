import { access, appendFile, readFile, mkdir, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline';
import { execFileSync } from 'node:child_process';
import { validateConfig, vocabularyTerms, modes, outputGuard, rawResult, joinRecognitionSegments } from './core.mjs';
import { timedAsr } from './timed-asr.mjs';
import { buildHistory } from '../scripts/refiner-common.mjs';

// stdout is reserved for private, local JSON messages to the native shell.
const emit = value => process.stdout.write(JSON.stringify(value) + '\n');
const configPath = process.argv[2];
const replayTrace = process.env.QVAC_REPLAY_RECEIVER && process.env.QVAC_REPLAY_TRACE === '1'
  ? resolve(dirname(configPath), 'benchmark-worker.jsonl') : null;
const replayCacheKey = replayTrace && process.env.QVAC_REPLAY_CACHE === '1'
  ? 'rambleflow-public-audio-replay-' + process.pid : false;
let sdk, asrId, refinerId, current, loading = true, cleanupPromise;
let config, timedRecognizer;
// The SDK runs the models in a helper process that does not always exit with this one. Each survivor
// keeps hundreds of megabytes of model memory until logout, so take any helper down on the way out.
function exitNow(code) {
  try {
    for (const pid of execFileSync('/usr/bin/pgrep', ['-P', String(process.pid)], { encoding: 'utf8' }).split('\n').filter(Boolean)) {
      try { process.kill(Number(pid), 'SIGKILL'); } catch { /* already gone */ }
    }
  } catch { /* pgrep exits non-zero when there are no children */ }
  process.exit(code);
}
const unsettled = Symbol('unsettled');
const within = (promise, ms) => {
  let timer;
  return Promise.race([Promise.resolve(promise).catch(() => {}), new Promise(resolve => { timer = setTimeout(resolve, ms, unsettled); })]).finally(() => clearTimeout(timer));
};
const closeLimit = Number(process.env.QVAC_CLOSE_LIMIT_MS ?? 3000);
// Start recognition and cleanup previews during dictation. The final whole
// recording still controls which transcript is eligible for insertion.
const pipelinedPreview = (!replayTrace && process.env.QVAC_SEGMENTED_RECOGNITION !== '1') ||
  (replayTrace && process.env.QVAC_REPLAY_PIPELINED_PREVIEW === '1');
const backgroundCleanup = pipelinedPreview || process.env.QVAC_BACKGROUND_CLEANUP === '1';
const replayReleaseTail = replayTrace && process.env.QVAC_REPLAY_RELEASE_TAIL === '1';
const segmentedRecognition = replayReleaseTail || (!pipelinedPreview && process.env.QVAC_SEGMENTED_RECOGNITION === '1');
const joinSegments = replayReleaseTail || (replayTrace && process.env.QVAC_REPLAY_DEDUP_JOINS === '1')
  ? joinRecognitionSegments : segments => segments.join(' ');
const adaptiveRefinerLimit = replayTrace && process.env.QVAC_REPLAY_ADAPTIVE_LIMIT === '1';
const replayOmissionRetry = replayTrace && process.env.QVAC_REPLAY_OMISSION_RETRY === '1';
const replayBothEdgeRetry = replayTrace && process.env.QVAC_REPLAY_BOTH_EDGE_RETRY === "1";
const selectiveBothEdgeRetry = replayBothEdgeRetry && process.env.QVAC_REPLAY_SELECTIVE_RETRY === '1';
const replaySeparateEdges = selectiveBothEdgeRetry && process.env.QVAC_REPLAY_SEPARATE_EDGES === '1';
const retryWithTrim = process.env.QVAC_RETRY_TRIM !== '0';
const replayPauseMs = replayTrace ? Number(process.env.QVAC_REPLAY_PAUSE_MS) : NaN;
const cancelStalePreview = pipelinedPreview || (replayTrace && process.env.QVAC_REPLAY_CANCEL_STALE === '1');
const replayExactRecognitionReuse = replayTrace && process.env.QVAC_REPLAY_EXACT_ASR_REUSE === '1';
const terminalPeriodReuse = !replayTrace || process.env.QVAC_REPLAY_TERMINAL_PERIOD === '1';
const replayTailFirstRetry = replayTrace && process.env.QVAC_REPLAY_TAIL_FIRST_RETRY === '1';
const replayExtendedWait = replayTrace && process.env.QVAC_REPLAY_EXTENDED_WAIT === '1';
const quietSamples = Number.isInteger(replayPauseMs) && replayPauseMs >= 100 && replayPauseMs <= 2000
  ? replayPauseMs * 16 : pipelinedPreview ? 3200 : 6400;
const trimMarginSamples = 3200;
async function cleanup() {
  if (cleanupPromise) return cleanupPromise;
  cleanupPromise = (async () => {
    const errors = [];
    timedRecognizer?.close();
    // `current` can be cleared by a finishing session while this waits.
    const state = current;
    if (state) state.cancelled = true;
    if (state) await drainCancelled(state);
    for (const modelId of [asrId, refinerId].filter(Boolean)) {
      try { await sdk.unloadModel({ modelId, clearStorage: false }); } catch (error) { errors.push(error.message); }
    }
    try { await sdk?.close(); } catch (error) { errors.push(error.message); }
    if (errors.length) throw new Error(errors.join('; '));
  })();
  return cleanupPromise;
}
const latestTimedPreview = !replayTrace || process.env.QVAC_REPLAY_LATEST_PREVIEW === '1';
const formattingPreview = !replayTrace || process.env.QVAC_REPLAY_FORMATTING_PREVIEW === '1';
const allowPunctuationReuse = () => replayTrace ? formattingPreview : config?.timedAsr?.formattingReuse === true;

function samePreviewWording(state, before, after) {
  if (before === after) return true;
  if (!allowPunctuationReuse() || !state.timedAudio || state.mode !== 'minimal' || !before || !after) return false;
  // Keep sentence boundaries, negation, case, digits and lexical tokens exact.
  const normalize = text => text.replace(/(?<=\p{L}),(?= \p{L})/gu, '').replace(/(?<=\p{L})-(?=\p{L})/gu, ' ');
  return normalize(before) === normalize(after);
}

async function refine(state, raw) {
  if (!raw.trim()) return { raw: '', text: '', warning: 'No speech detected.' };
  if (raw.length > 6000) return { raw, text: raw, warning: 'App input length limit reached. Raw transcript retained.' };
  const predict = adaptiveRefinerLimit ? Math.min(768, Math.max(96, raw.trim().split(/\s+/u).length * 4)) : 768;
  try {
  const history = buildHistory({ mode: state.mode, transcript: raw, vocabulary: state.vocabulary }, 'matched');
  if (state.vocabulary.length) {
    history[0].content += '\nUse the exact spelling of a vocabulary entry when the transcript clearly refers to that term, even if speech recognition spelled it differently. Preserve unrelated words and names.';
  }
  if (formattingPreview && state.timedAudio && state.mode === 'minimal') {
    history[0].content += '\nCorrect misplaced sentence boundaries, punctuation and capitalization. Preserve the words and meaning, including names and numbers.';
  }
  const request = sdk.completion({ modelId: refinerId,
    history, stream: true, kvCache: replayCacheKey,
    generationParams: { predict, temp: 0, repeat_penalty: 1, reasoning_budget: 0, seed: 42 } });
  state.request = request;
  void request.final.catch(() => {});
  for await (const event of request.events) { /* Consume the native stream to completion. */ }
  const result = await request.final;
  const warning = outputGuard(raw, result.contentText, result.stopReason, result.stats);
  return { raw, text: warning ? raw : result.contentText.trim(), warning, stopReason: result.stopReason, generatedTokens: result.stats?.generatedTokens,
    ...(replayTrace && state.replayEligible ? { refinerTiming: {
      timeToFirstToken: result.stats?.timeToFirstToken, tokensPerSecond: result.stats?.tokensPerSecond,
    } } : {}) };
  } catch (error) {
    return { raw, text: raw, warning: `Refinement failed. Raw transcript retained. ${error.message}` };
  }
}
function start(message) {
  if (loading) throw new Error('Models are still loading.');
  if (current) throw new Error('A dictation is already active.');
  if (!modes.has(message.mode)) throw new Error('Unknown writing mode.');
  current = {
    id: message.id, mode: message.mode, vocabulary: vocabularyTerms(message.vocabulary ?? config.vocabulary),
    cleanup: message.cleanup !== false, replayEligible: message.replayEligible === true, cancelled: false, samples: 0, nonzeroSamples: 0,
    peak: 0, energy: 0, firstLoud: -1, lastLoud: -1, lastSnapshot: -1, chunks: [], segmentEnd: 0, segments: [],
  };
  if (timedRecognizer?.available && (!replayTrace || current.replayEligible)) {
    current.timedAudio = [];
    current.timedBytes = 0;
    timedRecognizer.start(current.id, current.vocabulary);
  }
  emit({ type: 'recording', id: current.id });
}

async function recognize(state, pcm) {
  const request = sdk.transcribe({ modelId: asrId, audioChunk: pcm });
  state.request = request;
  return (await request).trim();
}

function prepareSnapshot(state) {
  if ((!segmentedRecognition && !backgroundCleanup) || state.finishing || state.cancelled ||
      state.preview || state.segmentFailed || state.lastLoud < 0 ||
      state.samples - state.lastLoud < quietSamples || state.lastLoud === state.lastSnapshot) return;
  state.lastSnapshot = state.lastLoud;
  // Leave half the verified pause for the next segment, so the join
  // retains quiet audio on both sides without repeating speech.
  const boundary = replayReleaseTail ? state.lastLoud + Math.floor(quietSamples / 2) : state.samples;
  const pcm = Buffer.concat(state.chunks).subarray(state.segmentEnd * 2, boundary * 2);
  state.preview = (async () => {
    const text = await recognize(state, pcm);
    if (state.cancelled) return;
    if (replayExactRecognitionReuse && state.replayEligible && !segmentedRecognition) {
      state.recognitionSnapshot = { samples: boundary, text };
    }
    if (segmentedRecognition) {
      if (!text) { state.segmentFailed = true; return; }
      state.segments.push(text);
      state.segmentEnd = boundary;
    }
    if (!backgroundCleanup || !state.cleanup || !text || state.finishing || state.lastLoud !== state.lastSnapshot) return;
    const raw = segmentedRecognition ? joinSegments(state.segments) : text;
    state.previewRefining = true;
    state.previewRaw = raw;
    const result = await refine(state, raw);
    if (!state.cancelled && !state.previewCancelSent && !result.warning) state.prepared = result;
  })().catch(() => {
    if (segmentedRecognition && state.segmentEnd !== boundary) state.segmentFailed = true;
  }).finally(() => {
    state.preview = undefined;
    state.previewRefining = false;
    state.previewRaw = undefined;
    state.previewCancelSent = false;
    prepareSnapshot(state);
  });
}

async function finalRecognition(state, deferFallback = false) {
  if (state.samples < 1600 || !state.nonzeroSamples) return '';
  const pcm = Buffer.concat(state.chunks);
  if (state.timedAudio && !state.timedFinished) {
    state.timedFinished = true;
    if (state.timedBytes) timedRecognizer.audio(state.id, Buffer.concat(state.timedAudio));
    try {
      const text = await timedRecognizer.finish(state.id);
      if (text && !state.cancelled) {
        state.releasePath = 'timestamp-overlap';
        return text;
      }
    } catch { /* Retain the whole-recording QVAC fallback. */ }
    if (state.cancelled) return '';
    if (deferFallback) return null;
  }
  if (!state.segmentFailed && state.segmentEnd > 0) {
    if (state.lastLoud < state.segmentEnd) {
      state.releasePath = 'committed';
      return joinSegments(state.segments);
    }
    try {
      const tail = await recognize(state, pcm.subarray(state.segmentEnd * 2));
      if (tail && !state.cancelled) {
        state.releasePath = 'tail';
        return joinSegments([...state.segments, tail]);
      }
    } catch (error) {
      if (!replayReleaseTail) throw error;
    }
    if (state.cancelled) return '';
    state.segmentFailed = true;
  }
  // Recording chunks are append-only. Equal sample counts identify identical PCM.
  const snapshot = state.recognitionSnapshot;
  state.recognitionReused = snapshot?.samples === state.samples;
  const raw = state.recognitionReused ? snapshot.text : await recognize(state, pcm);
  if (raw && !state.cancelled && state.replayEligible && state.firstLoud >= 0 &&
      (replayBothEdgeRetry || (replayOmissionRetry && state.firstLoud >= 6400))) {
    const words = text => text.toLowerCase().replaceAll('’', "'").match(/[a-z0-9]+(?:'[a-z0-9]+)*/gu) ?? [];
    const original = words(raw);
    const activeSeconds = (state.lastLoud - state.firstLoud + 1) / 16000;
    const initialWordCount = raw.trim().split(/\s+/u).length;
    const recordingSeconds = (state.samples - state.firstLoud) / 16000;
    if (replayBothEdgeRetry) state.omissionInput = { initialWordCount, recordingSeconds };
    const shouldRetry = replayBothEdgeRetry
      ? !selectiveBothEdgeRetry || initialWordCount < recordingSeconds * (replaySeparateEdges ? 1.7 : 1.5)
      : original.length < activeSeconds * 1.25;
    if (original.length && shouldRetry) {
      state.omissionRetried = true;
      try {
        const start = Math.max(0, state.firstLoud - trimMarginSamples);
        const end = replayBothEdgeRetry ? Math.min(state.samples, state.lastLoud + 1 + trimMarginSamples) : state.samples;
        const ranges = replaySeparateEdges
          ? [[start, state.samples], [0, end]].filter(([from, to]) => from > 0 || to < state.samples)
          : [[start, end]];
        const tailFirst = replaySeparateEdges && selectiveBothEdgeRetry && replayTailFirstRetry;
        if (tailFirst) ranges.reverse();
        let recovered = raw;
        let bestLength = original.length + 1;
        for (const [from, to] of ranges) {
          if (state.cancelled) return '';
          const alternate = await recognize(state, pcm.subarray(from * 2, to * 2));
          const candidate = words(alternate);
          if ((candidate.length > bestLength ||
              (tailFirst && from > 0 && recovered !== raw && candidate.length === bestLength)) && original.every((word, index) => word === candidate[index])) {
            recovered = alternate;
            bestLength = candidate.length;
            if (tailFirst && from === 0 && alternate.split(/\s+/u).length >= recordingSeconds * 1.7) break;
          }
        }
        if (recovered !== raw && !state.cancelled) {
          state.omissionRecovered = true;
          return recovered;
        }
      } catch (error) {
        state.omissionRetryError = error.message;
      }
    }
  }
  if (raw || state.cancelled || !retryWithTrim || state.firstLoud < 0) return raw;
  const start = Math.max(0, state.firstLoud - trimMarginSamples);
  const end = Math.min(state.samples, state.lastLoud + 1 + trimMarginSamples);
  if (start === 0 && end === state.samples) return raw;
  state.trimRetried = true;
  return recognize(state, pcm.subarray(start * 2, end * 2));
}

async function drainCancelled(state) {
  if (state.request?.requestId) await within(sdk.cancel({ requestId: state.request.requestId }), 2000);
  return await within(state.finalTask ?? state.preview, closeLimit) !== unsettled;
}

function refineLatestTimedPreview(state) {
  if (state.preview || state.finishing || state.cancelled) return;
  const raw = state.pendingTimedPreview;
  state.pendingTimedPreview = undefined;
  if (raw && !samePreviewWording(state, state.prepared?.raw, raw)) startTimedPreview(state, raw);
}

function startTimedPreview(state, raw) {
  state.lastSnapshot = state.lastLoud;
  state.previewRaw = raw;
  state.previewRefining = true;
  state.preview = refine(state, raw).then(result => {
    if (!state.cancelled && !state.previewCancelSent && !result.warning) state.prepared = result;
  }).finally(() => {
    state.preview = undefined;
    state.previewRaw = undefined;
    state.previewRefining = false;
    state.previewCancelSent = false;
    refineLatestTimedPreview(state);
  });
}

async function finish(message) {
  const state = current;
  if (!state || state.id !== message.id) throw new Error('No matching recording.');
  if (state.finishing) return;
  state.finishing = true;
  emit({ type: 'processing', id: state.id });
  const started = performance.now();
  const previewAtStop = state.preview ? (state.previewRefining ? 'refining' : 'recognizing') : 'idle';
  const preparedAtStop = state.prepared;
  const previewRawAtStop = state.previewRaw;
  state.finalTask = (async () => {
    const startRecognition = (deferFallback = false) => {
      const start = performance.now();
      return finalRecognition(state, deferFallback).then(raw => ({ raw, recognitionMs: performance.now() - start }));
    };
    const concurrentRecognition = state.timedAudio && latestTimedPreview;
    const recognition = concurrentRecognition ? startRecognition(true) : undefined;
    void recognition?.catch(() => {});
    const preview = state.preview;
    const final = recognition ? await recognition : undefined;
    const stale = final ? !samePreviewWording(state, state.previewRaw, final.raw) : state.lastLoud !== state.lastSnapshot;
    const previewWaitMs = replayExtendedWait && state.replayEligible && state.previewRefining ? 450 : 250;
    if (preview && (stale || await within(preview, previewWaitMs) === unsettled)) {
      if (state.preview && state.request?.requestId) {
        void sdk.cancel({ requestId: state.request.requestId }).catch(() => {});
      }
      if (await within(preview, 1500) === unsettled) {
        state.cancelled = true;
        throw new Error('Background inference did not stop in time.');
      }
    }
    if (state.cancelled) return;
    const { raw, recognitionMs } = final?.raw != null ? final : await startRecognition();
    if (state.cancelled) return;
    const prepared = state.prepared;
    const periodReuse = terminalPeriodReuse && state.mode === 'minimal' && prepared &&
      /[\p{L}\p{N}]$/u.test(prepared.raw) && raw === prepared.raw + '.' &&
      (prepared.text.endsWith('.') || /[\p{L}\p{N}]$/u.test(prepared.text));
    const formattingReuse = Boolean(prepared && prepared.raw !== raw && samePreviewWording(state, prepared.raw, raw));
    const reused = Boolean(state.cleanup && (prepared?.raw === raw || periodReuse || formattingReuse));
    const cleanupStart = performance.now();
    if (!state.cancelled) {
      const result = state.samples < 1600 ? { raw: '', text: '', warning: 'Recording was too short.' }
        : state.nonzeroSamples === 0 ? { raw: '', text: '', warning: 'No audio signal detected.' }
          : reused ? (periodReuse ? { ...prepared, raw, text: prepared.text.endsWith('.') ? prepared.text : prepared.text + '.' } : { ...prepared, raw }) : state.cleanup ? await refine(state, raw) : rawResult(raw);
      // Signal facts only, for telling "the microphone gave nothing" from "the recognizer heard nothing".
      const audio = { seconds: +(state.samples / 16000).toFixed(2), peak: +(state.peak / 32768).toFixed(3),
        rms: +(Math.sqrt(state.energy / Math.max(1, state.samples)) / 32768).toFixed(4),
        quietLead: state.firstLoud < 0 ? null : +(state.firstLoud / 16000).toFixed(2),
        recognitionMs, cleanupMs: performance.now() - cleanupStart, workerMs: performance.now() - started, reused,
        recognitionReused: Boolean(state.recognitionReused), completedSegments: state.segments.length, segmentFallback: Boolean(state.segmentFailed), trimRetried: Boolean(state.trimRetried) };
      if (!state.cancelled) {
        const message = { type: 'result', id: state.id, ...result, audio };
        if (current === state) current = null;
        emit(message);
        if (replayTrace && state.replayEligible) {
          const trace = { ...message, completedSegmentTexts: state.segments, omissionRetried: Boolean(state.omissionRetried),
            previewAtStop, formattingReuse, releasePath: state.releasePath ?? 'whole', periodReuse: Boolean(periodReuse && reused), preparedAtStop: Boolean(preparedAtStop), preparedRawAtStop: preparedAtStop?.raw, activePreviewMatchesFinal: previewRawAtStop === undefined ? null : previewRawAtStop === raw, preparedMatchesFinal: state.prepared?.raw === raw,
            stalePreviewCancels: state.stalePreviewCancels ?? 0, omissionInput: state.omissionInput, omissionRecovered: Boolean(state.omissionRecovered), omissionRetryError: state.omissionRetryError };
          if (process.env.QVAC_REPLAY_PCM === '1' && /^[a-f0-9-]{36}$/iu.test(state.id)) {
            const pcmFile = `benchmark-${state.id}.s16le`;
            try {
              await writeFile(resolve(dirname(replayTrace), pcmFile), Buffer.concat(state.chunks), { flag: 'wx', mode: 0o600 });
              trace.pcmFile = pcmFile;
            } catch (error) {
              trace.pcmError = error.code ?? 'unknown';
            }
          }
          await appendFile(replayTrace, JSON.stringify(trace) + '\n', { mode: 0o600 });
        }
      }
    }
  })();
  try { await state.finalTask; }
  finally { if (current === state && !state.cancelled) current = null; }
}
async function handle(message) {
  if (message.type === 'shutdown') {
    try { await cleanup(); emit({ type: 'closed' }); exitNow(0); }
    catch (error) { emit({ type: 'fatal', message: error.message }); exitNow(1); }
  }
  if (message.type === 'cancel') {
    if (current?.id !== message.id) return;
    const state = current;
    state.cancelled = true;
    const closed = await drainCancelled(state);
    if (current === state) current = null;
    emit({ type: 'cancelled', id: state.id, ...(closed ? {} : { stuck: true }) });
    return;
  }
  if (message.type === 'start') return start(message);
  if (message.type === 'stop') return finish(message);
  if (message.type === 'audio') {
    if (!current || current.id !== message.id || current.cancelled || current.finishing) throw new Error('Audio arrived outside its recording.');
    const bytes = Buffer.from(message.data, 'base64');
    if (!bytes.length || bytes.length > 64000 || bytes.length % 2) throw new Error('Invalid 16 kHz mono s16le audio chunk.');
    current.samples += bytes.length / 2;
    for (let offset = 0; offset < bytes.length; offset += 2) {
      const sample = bytes.readInt16LE(offset), size = Math.abs(sample);
      if (sample !== 0) current.nonzeroSamples++;
      if (size > current.peak) current.peak = size;
      current.energy += sample * sample;
      // About -30 dB of full scale: clearly louder than a quiet room.
      if (size > 1000) {
        current.lastLoud = current.samples - bytes.length / 2 + offset / 2;
        if (current.firstLoud < 0) current.firstLoud = current.lastLoud;
      }
    }
    if (current.samples > 16000 * 90) throw new Error('Recording exceeded 90 seconds.');
    current.chunks.push(bytes);
    if (cancelStalePreview && (!replayTrace || current.replayEligible) && (!segmentedRecognition || replayReleaseTail) && current.previewRefining &&
        !current.previewCancelSent && current.lastLoud !== current.lastSnapshot && current.request?.requestId) {
      current.previewCancelSent = true;
      current.stalePreviewCancels = (current.stalePreviewCancels ?? 0) + 1;
      void sdk.cancel({ requestId: current.request.requestId }).catch(() => {});
    }
    if (current.timedAudio) {
      current.timedAudio.push(bytes);
      current.timedBytes += bytes.length;
      if (current.timedBytes >= 12800) {
        timedRecognizer.audio(current.id, Buffer.concat(current.timedAudio));
        current.timedAudio = [];
        current.timedBytes = 0;
      }
    } else {
      prepareSnapshot(current);
    }
    return;
  }
  throw new Error('Unknown worker command.');
}
try {
  config = JSON.parse(await readFile(configPath, 'utf8'));
  // An older installer stored the bundled refiner in the replaceable speech runtime.
  // Recover its identical bundled weights when that legacy path disappears on upgrade.
  if (config.modelPath && !config.adapterPath) {
    try {
      await access(config.modelPath);
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
      let manifest;
      try {
        manifest = JSON.parse(await readFile(new URL('./default-refiner.json', import.meta.url), 'utf8'));
      } catch (manifestError) {
        if (manifestError.code !== 'ENOENT') throw manifestError;
      }
      if (manifest?.base.sha256 === config.modelSha256) {
        delete config.modelPath;
        delete config.modelSha256;
      }
    }
  }
  if (!config.modelPath && !config.adapterPath) {
    const manifest = JSON.parse(await readFile(new URL('./default-refiner.json', import.meta.url), 'utf8'));
    const models = new URL('../models/', import.meta.url);
    config.modelPath = fileURLToPath(new URL(manifest.base.file, models));
    config.modelSha256 = manifest.base.sha256;
    if (manifest.adapter) {
      config.adapterPath = fileURLToPath(new URL(manifest.adapter.file, models));
      config.adapterSha256 = manifest.adapter.sha256;
      config.adapterBaseSha256 = manifest.base.sha256;
    }
  }
  config = await validateConfig(config);
  await mkdir(config.cacheDirectory, { recursive: true });
  const runtime = resolve(dirname(configPath), 'qvac-runtime.json');
  await writeFile(runtime, JSON.stringify({ cacheDirectory: config.cacheDirectory, loggerConsoleOutput: false, loggerLevel: 'error' }), { mode: 0o600 });
  process.env.QVAC_CONFIG_PATH = runtime;
  sdk = await import('@qvac/sdk');
  const speechSrc = sdk.PARAKEET_TDT_0_6B_V3_Q4_0, refinerSrc = config.modelPath;
  // The app draws first-run progress from these: each model's size up front (a local file has none), then byte counts.
  emit({ type: 'models', models: [{ key: 'speech', bytes: speechSrc.expectedSize ?? null }, { key: 'cleanup', bytes: refinerSrc.expectedSize ?? null }] });
  const progress = key => {
    let last = 0;
    return p => {
      const overall = p.shardInfo ?? p.fileSetInfo;
      const downloaded = overall?.overallDownloaded ?? p.downloaded, total = overall?.overallTotal ?? p.total;
      // At most ten updates a second, but the last one always goes out.
      if (downloaded < total && Date.now() - last < 100) return;
      last = Date.now();
      emit({ type: 'progress', model: key, downloaded, total });
    };
  };
  emit({ type: 'loading', model: 'speech', message: 'Loading local speech recognition' });
  asrId = await sdk.loadModel({ modelSrc: speechSrc, modelType: 'parakeet-transcription',
    modelConfig: { useGPU: !(replayTrace && process.env.QVAC_REPLAY_CPU_ASR === '1'), sampleRate: 16000, channels: 1, maxThreads: 4, streaming: false }, onProgress: progress('speech') });
  emit({ type: 'loaded', model: 'speech' });
  emit({ type: 'loading', model: 'cleanup', message: 'Loading local refiner' });
  refinerId = await sdk.loadModel({ modelSrc: refinerSrc, modelType: 'llamacpp-completion',
    modelConfig: { ctx_size: 4096, device: 'gpu', temp: 0, repeat_penalty: 1, reasoning_budget: 0, verbosity: 0, ...(config.adapterPath ? { lora: config.adapterPath } : {}) }, onProgress: progress('cleanup') });
  emit({ type: 'loaded', model: 'cleanup' });
  loading = false;
  const timedPaths = [
    process.env.RAMBLE_TIMED_PYTHON ?? config.timedAsr?.python,
    process.env.RAMBLE_TIMED_SERVER ?? config.timedAsr?.server,
    process.env.RAMBLE_TIMED_MODEL ?? config.timedAsr?.model,
  ];
  const timedConfigured = timedPaths.every(path => typeof path === 'string' && path.startsWith('/') && !path.includes('\0'));
  if (replayTrace ? process.env.QVAC_REPLAY_TIMED_ASR === '1' : timedConfigured) {
    if (!timedConfigured) throw new Error('Timed ASR paths missing');
    timedRecognizer = timedAsr(...timedPaths, (id, raw) => {
      const state = current;
      if (state?.id !== id || !raw || !state.cleanup || state.cancelled || state.finishing) return;
      if (latestTimedPreview) {
        state.pendingTimedPreview = raw;
        refineLatestTimedPreview(state);
      } else if (!state.preview && raw !== state.prepared?.raw) {
        startTimedPreview(state, raw);
      }
    });
    try {
      await timedRecognizer.ready;
    } catch (error) {
      timedRecognizer.close();
      timedRecognizer = undefined;
      if (replayTrace) throw error;
    }
  }
  emit({ type: 'ready' });
  const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
  // Do not block audio or cancellation behind a pending native stop/completion.
  lines.on('line', line => {
    try {
      if (line.length > 100000) throw new Error('Worker message too large.');
      const message = JSON.parse(line);
      void handle(message).catch(error => emit({ type: 'error', id: message.id, message: error.message }));
    } catch (error) { emit({ type: 'error', message: error.message }); }
  });
  lines.on('close', () => { void within(cleanup(), 4000).finally(() => exitNow(0)); });
} catch (error) {
  emit({ type: 'fatal', message: error.message });
  await cleanup().catch(() => {});
  exitNow(1);
}
// Cleanup can hang on a recognizer that will not stop, and must not keep an orphaned process alive.
for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => { void within(cleanup(), 4000).finally(() => exitNow(0)); });
