import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';

// Set the vocabulary bias in the sidecar process without modifying its installed files.
const launchSidecar = `
import os
import runpy
import sys

server = sys.argv[1]
sys.argv = sys.argv[1:]
sidecar_dir = os.path.dirname(server)
sys.path.insert(0, sidecar_dir)
if os.path.isfile(os.path.join(sidecar_dir, "asr_terms.py")):
    import asr_terms
    # Favor completing a saved term, with a cap to limit substitutions.
    asr_terms.S_CONT = 8.0
    asr_terms.BUDGET = 8.0
runpy.run_path(server, run_name="__main__")
`;

export function timedAsr(python, server, model, onPreview) {
  const child = spawn(python, ['-c', launchSidecar, server, '--model', model], {
    stdio: ['pipe', 'pipe', 'ignore'],
    env: { ...process.env, HF_HUB_OFFLINE: '1', PYTHONDONTWRITEBYTECODE: '1' },
  });
  let pending;
  let lastTerms = "[]";
  let unavailable = false;
  const fail = error => {
    unavailable = true;
    pending?.reject(error);
  };
  const send = message => child.stdin.write(JSON.stringify(message) + '\n');
  const request = (message, accepts, timeoutMs) => {
    if (unavailable || pending) return Promise.reject(new Error('Timed recognizer unavailable'));
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        fail(new Error('Timed recognizer timed out'));
        child.kill();
      }, timeoutMs);
      const settle = callback => value => {
        clearTimeout(timer);
        pending = undefined;
        callback(value);
      };
      pending = { accepts, resolve: settle(resolve), reject: settle(reject) };
      if (message) send(message);
    });
  };

  child.on('error', fail);
  child.stdin.on('error', fail);
  child.on('exit', () => fail(new Error('Timed recognizer exited')));
  createInterface({ input: child.stdout }).on('line', line => {
    let message;
    try { message = JSON.parse(line); } catch { return; }
    if (message.type === 'error') {
      fail(new Error(String(message.msg)));
      child.kill();
    } else if (pending?.accepts(message)) {
      pending.resolve(message);
    } else if (message.type === 'segment') {
      onPreview(message.id, message.preview);
    }
  });

  return {
    get available() { return !unavailable; },
    ready: request(null, message => message.type === 'ready', 45000),
    start(id, terms = []) {
      if (unavailable) return;
      const serialized = JSON.stringify(terms);
      if (serialized !== lastTerms) {
        send({ cmd: 'terms', terms });
        lastTerms = serialized;
      }
      send({ cmd: 'stream_start', id, segments: true, stable_commits: true });
    },
    audio(id, pcm) {
      if (!unavailable) send({ cmd: 'stream_chunk', id, pcm16: pcm.toString('base64') });
    },
    async finish(id) {
      const result = await request({ cmd: 'stream_finish', id },
        message => message.id === id && message.type === 'result' && message.partial === false, 1500);
      return result.text.trim();
    },
    close() { child.kill(); },
  };
}
