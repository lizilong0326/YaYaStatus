import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

const PACKAGE_NAME = 'doubao-cli';
const REGISTRY_URL = `https://registry.npmjs.org/${PACKAGE_NAME}/latest`;
const CHECK_INTERVAL_MS = 24 * 60 * 60 * 1000;
const DEFAULT_STATE = Object.freeze({
  autoUpdate: false,
  lastCheckedAt: null,
  lastUpdatedVersion: null,
});

function parseVersion(version) {
  const match = /^(?:v)?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?$/u.exec(String(version || '').trim());
  if (!match) throw new Error(`invalid semantic version "${version}"`);
  return {
    numbers: match.slice(1, 4).map(Number),
    prerelease: match[4]?.split('.') || [],
  };
}

function comparePrerelease(left, right) {
  if (!left.length && !right.length) return 0;
  if (!left.length) return 1;
  if (!right.length) return -1;
  for (let index = 0; index < Math.max(left.length, right.length); index += 1) {
    if (left[index] === undefined) return -1;
    if (right[index] === undefined) return 1;
    if (left[index] === right[index]) continue;
    const leftNumber = /^\d+$/u.test(left[index]) ? Number(left[index]) : null;
    const rightNumber = /^\d+$/u.test(right[index]) ? Number(right[index]) : null;
    if (leftNumber !== null && rightNumber !== null) return Math.sign(leftNumber - rightNumber);
    if (leftNumber !== null) return -1;
    if (rightNumber !== null) return 1;
    return Math.sign(left[index].localeCompare(right[index], 'en-US'));
  }
  return 0;
}

export function compareVersions(leftVersion, rightVersion) {
  const left = parseVersion(leftVersion);
  const right = parseVersion(rightVersion);
  for (let index = 0; index < left.numbers.length; index += 1) {
    if (left.numbers[index] !== right.numbers[index]) {
      return Math.sign(left.numbers[index] - right.numbers[index]);
    }
  }
  return comparePrerelease(left.prerelease, right.prerelease);
}

export function updateStatePath(env = process.env) {
  const directory = env.DOUBAO_CLI_CONFIG_DIR
    || path.join(os.homedir(), 'Library', 'Application Support', PACKAGE_NAME);
  return path.join(directory, 'update.json');
}

export async function readUpdateState(env = process.env) {
  const statePath = updateStatePath(env);
  try {
    const parsed = JSON.parse(await fs.readFile(statePath, 'utf8'));
    return { ...DEFAULT_STATE, ...parsed };
  } catch (error) {
    if (error.code === 'ENOENT') return { ...DEFAULT_STATE };
    throw new Error(`cannot read update settings at ${statePath}: ${error.message}`);
  }
}

export async function writeUpdateState(state, env = process.env) {
  const statePath = updateStatePath(env);
  await fs.mkdir(path.dirname(statePath), { recursive: true });
  const temporaryPath = `${statePath}.${process.pid}.${Date.now()}.tmp`;
  try {
    await fs.writeFile(temporaryPath, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
    await fs.rename(temporaryPath, statePath);
  } finally {
    await fs.rm(temporaryPath, { force: true }).catch(() => {});
  }
  return state;
}

export async function setAutoUpdate(enabled, env = process.env) {
  const state = await readUpdateState(env);
  return writeUpdateState({
    ...state,
    autoUpdate: Boolean(enabled),
    ...(enabled ? { lastCheckedAt: null } : {}),
  }, env);
}

export async function checkForUpdate(currentVersion, options = {}) {
  parseVersion(currentVersion);
  const fetchImpl = options.fetchImpl || fetch;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), options.timeoutMs || 5000);
  try {
    const response = await fetchImpl(REGISTRY_URL, {
      headers: { accept: 'application/json' },
      signal: controller.signal,
    });
    if (!response.ok) throw new Error(`npm registry returned HTTP ${response.status}`);
    const payload = await response.json();
    parseVersion(payload.version);
    return {
      currentVersion,
      latestVersion: payload.version,
      updateAvailable: compareVersions(currentVersion, payload.version) < 0,
    };
  } finally {
    clearTimeout(timer);
  }
}

export function installUpdate(version, options = {}) {
  parseVersion(version);
  const spawnImpl = options.spawnImpl || spawnSync;
  const result = spawnImpl('npm', ['install', '--global', `${PACKAGE_NAME}@${version}`], {
    encoding: 'utf8',
    env: options.env || process.env,
    stdio: options.inherit ? 'inherit' : 'pipe',
  });
  if (result.error) throw new Error(`failed to run npm: ${result.error.message}`);
  if (result.status !== 0) {
    throw new Error(result.stderr?.trim() || `npm exited with status ${result.status}`);
  }
  return { updated: true, version };
}

function automaticUpdatesDisabled(env) {
  return /^(?:1|true|yes)$/iu.test(env.DOUBAO_CLI_DISABLE_AUTO_UPDATE || '');
}

// When automatic updates are off, still check the registry (throttled to the
// same interval) so the CLI can remind the user that an update exists.
// Returns the check result only when an update is available, otherwise null.
export async function maybeUpdateReminder(currentVersion, options = {}) {
  const env = options.env || process.env;
  if (automaticUpdatesDisabled(env)) return null;
  try {
    const state = await readUpdateState(env);
    if (state.autoUpdate) return null;
    const now = options.now || Date.now();
    const lastCheckedAt = state.lastCheckedAt ? Date.parse(state.lastCheckedAt) : 0;
    if (Number.isFinite(lastCheckedAt) && now - lastCheckedAt < (options.intervalMs || CHECK_INTERVAL_MS)) {
      return null;
    }
    const check = await checkForUpdate(currentVersion, options);
    await writeUpdateState({ ...state, lastCheckedAt: new Date(now).toISOString() }, env);
    return check.updateAvailable ? check : null;
  } catch {
    return null;
  }
}

export async function maybeAutoUpdate(currentVersion, options = {}) {
  const env = options.env || process.env;
  if (automaticUpdatesDisabled(env)) return { skipped: 'disabled' };
  try {
    const state = await readUpdateState(env);
    if (!state.autoUpdate) return { skipped: 'not-enabled' };

    const now = options.now || Date.now();
    const lastCheckedAt = state.lastCheckedAt ? Date.parse(state.lastCheckedAt) : 0;
    if (Number.isFinite(lastCheckedAt) && now - lastCheckedAt < (options.intervalMs || CHECK_INTERVAL_MS)) {
      return { skipped: 'not-due', state };
    }

    const check = await checkForUpdate(currentVersion, options);
    const nextState = {
      ...state,
      lastCheckedAt: new Date(now).toISOString(),
    };
    await writeUpdateState(nextState, env);
    if (!check.updateAvailable) {
      return { ...check, updated: false };
    }
    installUpdate(check.latestVersion, options);
    await writeUpdateState({
      ...nextState,
      lastUpdatedVersion: check.latestVersion,
    }, env);
    return { ...check, updated: true };
  } catch (error) {
    return { error: error.message };
  }
}
