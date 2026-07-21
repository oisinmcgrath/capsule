#!/usr/bin/env node
// @tagdex: active, core, script
// taskboard — persistent pending-work whiteboards. See taskboard/README.md.
// Paths anchor to this script's location, not process.cwd().

import {
  readFileSync, writeFileSync, renameSync, unlinkSync,
  existsSync, mkdirSync, readdirSync,
} from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, basename } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const LISTS_DIR = join(__dirname, 'lists');
const CONFIG_PATH = join(__dirname, 'config.json');
const DOMAINS_PATH = join(__dirname, 'domains.json');
const SUFFIX = '_whiteboard.json';
const LOCK_SUFFIX = '.lock';

// ── errors ─────────────────────────────────────────────────────────────
function die(msg) {
  process.stderr.write(`taskboard: ${msg}\n`);
  process.exit(1);
}

// ── paths & names ──────────────────────────────────────────────────────
function ensureListsDir() {
  if (!existsSync(LISTS_DIR)) mkdirSync(LISTS_DIR, { recursive: true });
}

function validateName(name) {
  if (!name) die('a whiteboard name is required');
  if (name.includes('/') || name.endsWith('.json') || name.endsWith('_whiteboard')) {
    die(`invalid name "${name}" — pass the bare name (e.g. "recorder", "recorder_focuslock"), not a path or filename`);
  }
  return name;
}

function filePath(name) { return join(LISTS_DIR, name + SUFFIX); }
function nameFromFile(file) { return basename(file, SUFFIX); }
function lockPath(file) { return file + LOCK_SUFFIX; }

// Domain = text before the first underscore; directory-sort groups <domain>_* together.
function domainOf(name) {
  const i = name.indexOf('_');
  return i === -1 ? name : name.slice(0, i);
}

// ── JSON I/O (atomic temp + rename) ────────────────────────────────────
function writeJsonAtomic(path, obj) {
  const tmp = `${path}.tmp.${process.pid}`;
  writeFileSync(tmp, JSON.stringify(obj, null, 2) + '\n', 'utf8');
  renameSync(tmp, path);
}

function loadConfig() {
  const defaults = { soft_max_items: 12 };
  if (!existsSync(CONFIG_PATH)) return defaults;
  try { return Object.assign(defaults, JSON.parse(readFileSync(CONFIG_PATH, 'utf8'))); }
  catch (e) { die(`reading ${CONFIG_PATH}: ${e.message}`); }
}

function loadDomains() {
  if (!existsSync(DOMAINS_PATH)) return [];
  try {
    const d = JSON.parse(readFileSync(DOMAINS_PATH, 'utf8'));
    if (!Array.isArray(d)) die(`${DOMAINS_PATH}: expected a JSON array`);
    return d;
  } catch (e) { die(`reading ${DOMAINS_PATH}: ${e.message}`); }
}

function readBoard(file) {
  if (!existsSync(file)) return [];
  let parsed;
  try { parsed = JSON.parse(readFileSync(file, 'utf8')); }
  catch (e) { die(`reading ${file}: ${e.message}`); }
  if (!Array.isArray(parsed)) die(`${file}: expected a JSON array of strings`);
  return parsed;
}

// Empty list ⇒ delete the file and its lock (present = pending, absent = done).
function writeBoard(file, items) {
  if (items.length === 0) {
    if (existsSync(file)) unlinkSync(file);
    const lf = lockPath(file);
    if (existsSync(lf)) unlinkSync(lf);
    return;
  }
  writeJsonAtomic(file, items);
}

// ── lock (sidecar PID file; reclaimed when the holder ppid is no longer alive)
// A dead holder's lock is stale by definition: in a container harness every
// command runs under a fresh, short-lived shell ppid, so without reclaim the
// next invocation would always see a foreign-and-dead holder. Reclaim keeps the
// "one live agent at a time" contract while clearing dead locks automatically.
function pidAlive(pid) {
  try { process.kill(pid, 0); return true; }
  catch (e) { return e.code === 'EPERM'; } // EPERM = alive but not signalable
}

function readLock(file) {
  const lp = lockPath(file);
  if (!existsSync(lp)) return null;
  try { return JSON.parse(readFileSync(lp, 'utf8')); }
  catch (e) { die(`lockfile ${lp} is unreadable: ${e.message}`); }
}

function writeLock(file, pid) {
  writeFileSync(lockPath(file), JSON.stringify({ ppid: pid }) + '\n', 'utf8');
}

// Released at the end of every mutating op: the lock guards only the
// read-modify-write critical section, not the whole life of the calling
// process. Without this a one-shot CLI invocation would leave a lock the next
// invocation (a different ppid) cannot claim. No-op if already cleared (e.g.
// writeBoard deleted the file + lock because the list emptied).
function releaseLock(file) {
  const lp = lockPath(file);
  if (existsSync(lp)) unlinkSync(lp);
}

// Acquire on first mutation; same-ppid proceeds, foreign ppid is refused.
function assertLock(file) {
  const mine = process.ppid;
  const lock = readLock(file);
  if (lock === null) { writeLock(file, mine); return; }
  if (lock.ppid === mine) return;
  if (!pidAlive(lock.ppid)) { writeLock(file, mine); return; } // stale holder — reclaim
  die(`"${nameFromFile(file)}" held by live ppid ${lock.ppid} — see README for the refusal contract`);
}

// Renders the full board to STDOUT so every mutation lands in the Bash tool
// result the owner sees, with no reliance on the agent echoing it. Mirrors the
// native todo list: sequential 1-based numbering in priority (file) order, an
// "← added" marker on the item just inserted (opts.addedIndex).
function render(name, items, opts = {}) {
  const n = items.length;
  process.stdout.write(`${name}  (${n} item${n === 1 ? '' : 's'})\n`);
  items.forEach((it, i) => {
    const marker = opts.addedIndex === i ? '  ← added' : '';
    process.stdout.write(`  ${i + 1}. ☐ ${it}${marker}\n`);
  });
}

// Selector: 1-based index or unique case-insensitive substring → 0-based index.
function resolveSelector(items, query, name) {
  const asInt = Number(query);
  if (Number.isInteger(asInt) && String(asInt) === String(query).trim() && asInt >= 1 && asInt <= items.length) {
    return asInt - 1;
  }
  const needle = String(query).toLowerCase();
  const matches = items.map((content, i) => ({ i, content })).filter(m => m.content.toLowerCase().includes(needle));
  if (matches.length === 0) die(`no item on "${name}" matches "${query}"`);
  if (matches.length > 1) {
    process.stderr.write(`taskboard: "${query}" matches ${matches.length} items on "${name}":\n`);
    matches.forEach(m => process.stderr.write(`  ${m.i + 1}. ${m.content}\n`));
    die('narrow the substring or pass the 1-based index');
  }
  return matches[0].i;
}

// --owner is convention, not authentication — runs these only on explicit instruction.
function requireOwner(args, verb) {
  if (!args.includes('--owner')) {
    die(`"${verb}" is an owner-only operation — re-run with --owner (run only on explicit owner instruction)`);
  }
  return args.filter(a => a !== '--owner');
}

// ── verbs ──────────────────────────────────────────────────────────────
function allBoardFiles() {
  if (!existsSync(LISTS_DIR)) return [];
  return readdirSync(LISTS_DIR)
    .filter(f => f.endsWith(SUFFIX))
    .sort()
    .map(f => join(LISTS_DIR, f));
}

function cmdList(name) {
  if (name) {
    validateName(name);
    const file = filePath(name);
    if (!existsSync(file)) { process.stdout.write(`${name}  (no such whiteboard)\n`); return; }
    render(name, readBoard(file));
    return;
  }
  const files = allBoardFiles();
  if (files.length === 0) { process.stdout.write('(no whiteboards)\n'); return; }
  files.forEach((file, i) => {
    if (i > 0) process.stdout.write('\n');
    render(nameFromFile(file), readBoard(file));
  });
}

function cmdAdd(name, item) {
  validateName(name);
  if (!item) die('usage: taskboard add <name> "<item>"');
  ensureListsDir();

  // Lock first: a blocked agent must mutate nothing — not even domains.json.
  const file = filePath(name);
  assertLock(file);

  const domain = domainOf(name);
  const domains = loadDomains();
  if (!domains.includes(domain)) {
    domains.push(domain);
    domains.sort();
    writeJsonAtomic(DOMAINS_PATH, domains);
    process.stderr.write(`note: new domain "${domain}" added to domains.json (owner prunes later)\n`);
  }

  const items = readBoard(file);

  const cap = loadConfig().soft_max_items;
  if (items.length >= cap) {
    process.stderr.write(
      `warning: "${name}" already holds ${items.length} items (soft cap ${cap}) — ` +
      `scope may be too broad; consider splitting or pruning. Item added anyway.\n`
    );
  }

  items.push(item);
  writeBoard(file, items);
  releaseLock(file);
  render(name, items, { addedIndex: items.length - 1 });
}

function cmdRemove(name, query) {
  validateName(name);
  if (!query) die('usage: taskboard remove <name> <unique-substring|1-based-index>');
  const file = filePath(name);
  if (!existsSync(file)) die(`"${name}" does not exist`);
  assertLock(file);
  const items = readBoard(file);
  if (items.length === 0) die(`"${name}" is empty`);

  const idx = resolveSelector(items, query, name);
  const removed = items.splice(idx, 1)[0];
  writeBoard(file, items);
  releaseLock(file);
  // Crossed-off line to STDOUT mirrors a native todo being ticked done.
  process.stdout.write(`  ☑ ${removed}  ← crossed off (done)\n`);
  if (items.length === 0) {
    process.stdout.write(`${name} — last item removed, list deleted.\n`);
  } else {
    render(name, items);
  }
  process.stderr.write(`removed: ${removed}\n`);
}

function cmdDomains() {
  const domains = loadDomains();
  if (domains.length === 0) { process.stdout.write('(no domains)\n'); return; }
  for (const d of domains) process.stdout.write(`${d}\n`);
}

// ── owner-only verbs ─────────────────────────────────────────────────────
// These carry owner authority and bypass the per-list lock (unlock clears stale locks).
function cmdRename(args) {
  const [oldName, newName] = requireOwner(args, 'rename');
  validateName(oldName); validateName(newName);
  const oldF = filePath(oldName), newF = filePath(newName);
  if (!existsSync(oldF)) die(`"${oldName}" does not exist`);
  if (existsSync(newF)) die(`"${newName}" already exists`);
  const items = readBoard(oldF);
  writeBoard(newF, items);
  if (existsSync(lockPath(oldF))) renameSync(lockPath(oldF), lockPath(newF)); // preserve holder
  if (existsSync(oldF)) unlinkSync(oldF);
  process.stderr.write(`renamed "${oldName}" → "${newName}"\n`);
  render(newName, items);
}

function cmdMerge(args) {
  const [src, dest] = requireOwner(args, 'merge');
  validateName(src); validateName(dest);
  if (src === dest) die('source and destination are the same');
  const srcF = filePath(src), destF = filePath(dest);
  const merged = readBoard(destF).concat(readBoard(srcF));
  writeBoard(destF, merged);
  writeBoard(srcF, []); // deletes src file + its lock
  process.stderr.write(`merged "${src}" into "${dest}"; "${src}" deleted\n`);
  render(dest, merged);
}

function cmdSplit(args) {
  const [name, newName, ...selectors] = requireOwner(args, 'split');
  validateName(name); validateName(newName);
  if (selectors.length === 0) die('split requires at least one item selector (substring or 1-based index)');
  const srcF = filePath(name), newF = filePath(newName);
  if (!existsSync(srcF)) die(`"${name}" does not exist`);
  if (existsSync(newF)) die(`"${newName}" already exists`);
  const items = readBoard(srcF);
  const idxSet = new Set(selectors.map(sel => resolveSelector(items, sel, name)));
  const moved = [...idxSet].sort((a, b) => a - b).map(i => items[i]);
  const remaining = items.filter((_, i) => !idxSet.has(i));
  writeBoard(newF, moved);
  writeBoard(srcF, remaining); // src auto-deleted (+lock) if now empty
  process.stderr.write(`split: moved ${moved.length} item(s) from "${name}" to "${newName}"\n`);
  render(newName, moved);
  process.stdout.write('\n');
  if (remaining.length) render(name, remaining);
  else process.stdout.write(`${name} — emptied by split, list deleted.\n`);
}

function cmdDelete(args) {
  const [name] = requireOwner(args, 'delete');
  validateName(name);
  const f = filePath(name);
  if (!existsSync(f)) die(`"${name}" does not exist`);
  const count = readBoard(f).length;
  unlinkSync(f);
  if (existsSync(lockPath(f))) unlinkSync(lockPath(f));
  process.stdout.write(`deleted "${name}" (${count} item${count === 1 ? '' : 's'}).\n`);
}

function cmdUnlock(args) {
  const [name] = requireOwner(args, 'unlock');
  validateName(name);
  const lp = lockPath(filePath(name));
  if (!existsSync(lp)) { process.stdout.write(`"${name}" has no lock.\n`); return; }
  const lock = readLock(filePath(name));
  unlinkSync(lp);
  process.stdout.write(`unlocked "${name}" (was held by ppid ${lock ? lock.ppid : '?'}).\n`);
}

// ── help & dispatch ─────────────────────────────────────────────────────
function printHelp() {
  process.stdout.write(
`taskboard — persistent pending-work whiteboards

Usage:
  node taskboard/taskboard.js list                         List every whiteboard, grouped by domain.
  node taskboard/taskboard.js list <name>                  List one whiteboard.
  node taskboard/taskboard.js add <name> "<item>"          Append a pending-work item.
  node taskboard/taskboard.js remove <name> <text|index>   Remove by unique substring or 1-based index.
  node taskboard/taskboard.js domains                      Print the suggested-domains list.
  node taskboard/taskboard.js --help                       Show this help.

Owner-only (require --owner; run only on explicit owner instruction):
  node taskboard/taskboard.js rename <old> <new> --owner
  node taskboard/taskboard.js merge <src> <dest> --owner
  node taskboard/taskboard.js split <name> <newname> <text|index>... --owner
  node taskboard/taskboard.js delete <name> --owner
  node taskboard/taskboard.js unlock <name> --owner

<name> is the bare whiteboard name <domain>[_<freename>] (e.g. recorder, recorder_focuslock).
The file on disk is taskboard/lists/<name>${SUFFIX}. See taskboard/README.md for design intent.
`);
}

function main() {
  const [, , cmd, ...rest] = process.argv;
  switch (cmd) {
    case undefined:
    case '--help':
    case '-h':
      printHelp();
      return;
    case 'list':
      cmdList(rest[0]);
      return;
    case 'add':
      cmdAdd(rest[0], rest.slice(1).join(' '));
      return;
    case 'remove':
      cmdRemove(rest[0], rest[1]);
      return;
    case 'domains':
      cmdDomains();
      return;
    case 'rename':
      cmdRename(rest);
      return;
    case 'merge':
      cmdMerge(rest);
      return;
    case 'split':
      cmdSplit(rest);
      return;
    case 'delete':
      cmdDelete(rest);
      return;
    case 'unlock':
      cmdUnlock(rest);
      return;
    default:
      process.stderr.write(`taskboard: unknown command "${cmd}"\n\n`);
      printHelp();
      process.exit(1);
  }
}

main();
