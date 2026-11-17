// Select a local model and optional training-verified adapter. Never enables auto insertion.
import { readFile, writeFile, rename } from 'node:fs/promises';
import { resolve } from 'node:path';
import { checksum, validateConfig } from './core.mjs';

const [configFile, modelFile, adapterFile, reportFile] = process.argv.slice(2);
if (!configFile || !modelFile || Boolean(adapterFile) !== Boolean(reportFile)) throw new Error('Usage: node app/select-model.mjs CONFIG MODEL [ADAPTER TRAINING_REPORT]');
const configPath = resolve(configFile), modelPath = resolve(modelFile);
const config = JSON.parse(await readFile(configPath, 'utf8'));
config.modelPath = modelPath;
config.modelSha256 = await checksum(modelPath);
config.autoInsert = false;
delete config.adapterPath; delete config.adapterSha256; delete config.adapterBaseSha256;
if (adapterFile) {
  const report = JSON.parse(await readFile(resolve(reportFile), 'utf8'));
  const adapterPath = resolve(adapterFile), adapterSha256 = await checksum(adapterPath);
  if (report.status !== 'completed' || report.modelSha256 !== config.modelSha256) throw new Error('Training report must be completed and match this base model.');
  if (!report.artifacts?.some(artifact => artifact.sha256 === adapterSha256 && artifact.name === 'trained-lora-adapter.gguf')) throw new Error('Adapter checksum is not a final artifact in this training report.');
  Object.assign(config, { adapterPath, adapterSha256, adapterBaseSha256: config.modelSha256 });
}
await validateConfig(config);
const temporary = configPath + '.next';
await writeFile(temporary, JSON.stringify(config, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
await rename(temporary, configPath);
console.log('Local model selected and checksums verified. Preview remains enabled. Use Reload models in the app.');
