#!/usr/bin/env node
// tagdexer/indexer.js — vendored CLI indexer
// @tagdex: tool, core, active
//
// Usage:
//   node tagdexer/indexer.js              # full reindex from CWD
//   node tagdexer/indexer.js --file PATH  # incremental: rescan one file
//   node tagdexer/indexer.js --reconcile  # detect orphans in .tags files
//   node tagdexer/indexer.js --help
//
// Exit codes: 0 = success, non-zero = failure (reason on stderr).
// Runtime prerequisite: ripgrep (rg) must be on PATH.

import { randomUUID } from 'node:crypto';

import { execSync } from 'node:child_process';
import {
  readFileSync, writeFileSync, renameSync, unlinkSync,
  existsSync, statSync, readdirSync,
} from 'node:fs';
import { join, dirname, extname, relative, resolve, basename } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  loadAliases, resolveTag, parseHeader, parseTagsFile, parseTags,
  HEADER_EXTENSIONS, HEADER_MARKER_RE,
} from './shared/core.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const ROOT = process.cwd();
const TAGDEXER_DIR = __dirname;
const ALIASES_PATH = join(TAGDEXER_DIR, 'aliases.json');
const INDEX_PATH = join(ROOT, '.tagindex.json');
const LOCK_PATH = INDEX_PATH + '.lock';
const TAGDEXERIGNORE = join(ROOT, '.tagdexerignore');

// ─── Shared alias resolution ────────────────────────────────────────────────

function findGenericPath(args) {
  // --generic flag overrides everything (--canonical accepted for backward compat)
  let flagIdx = args.indexOf('--generic');
  if (flagIdx === -1) flagIdx = args.indexOf('--canonical');
  if (flagIdx !== -1 && args[flagIdx + 1]) {
    const p = resolve(args[flagIdx + 1]);
    const aliasesPath = p.endsWith('.json') ? p : join(p, 'aliases.json');
    if (existsSync(aliasesPath)) return aliasesPath;
    process.stderr.write(`Warning: shared aliases path not found: ${aliasesPath}\n`);
    return null;
  }
  // .tagdexerrc at repo root (genericPath= or canonicalPath= for backward compat)
  const rcPath = join(ROOT, '.tagdexerrc');
  if (existsSync(rcPath)) {
    const lines = readFileSync(rcPath, 'utf-8').split('\n');
    for (const line of lines) {
      const m = line.match(/^\s*(?:genericPath|canonicalPath)\s*=\s*(.+)/);
      if (m) {
        const p = resolve(m[1].trim());
        const aliasesPath = p.endsWith('.json') ? p : join(p, 'aliases.json');
        if (existsSync(aliasesPath)) return aliasesPath;
      }
    }
  }
  return null;
}

/** Check if --generic flag is present (or --canonical for backward compat) */
function hasGenericFlag(args) {
  return args.includes('--generic') || args.includes('--canonical');
}

function loadMergedAliases() {
  const genericPath = findGenericPath(process.argv);
  let shared = { aliasMap: {}, descriptions: {}, canonicalTags: [] };
  if (genericPath && genericPath !== ALIASES_PATH) {
    try { shared = loadAliases(genericPath); } catch { /* fallback */ }
  }
  let project = { aliasMap: {}, descriptions: {}, canonicalTags: [] };
  try { project = loadAliases(ALIASES_PATH); } catch { /* empty */ }
  return {
    aliasMap: { ...shared.aliasMap, ...project.aliasMap },
    descriptions: { ...shared.descriptions, ...project.descriptions },
    canonicalTags: [...new Set([...shared.canonicalTags, ...project.canonicalTags])].sort(),
    sharedTags: shared.canonicalTags,
    projectTags: project.canonicalTags,
    genericPath: genericPath,
  };
}

/** Load raw JSON from both alias files */
function loadBothRaw() {
  const genericPath = findGenericPath(process.argv);
  let sharedRaw = {};
  if (genericPath && genericPath !== ALIASES_PATH) {
    try { sharedRaw = JSON.parse(readFileSync(genericPath, 'utf-8')); } catch { /* ok */ }
  }
  let projectRaw = {};
  try { projectRaw = JSON.parse(readFileSync(ALIASES_PATH, 'utf-8')); } catch { /* ok */ }
  return { sharedRaw, projectRaw, genericPath };
}

/** Detect all string collisions between shared and project files */
function detectOverlaps(sharedRaw, projectRaw) {
  // Build string→source maps
  const sharedStrings = new Map(); // string → { type: 'canonical'|'alias', parent: tag }
  for (const [tag, entry] of Object.entries(sharedRaw)) {
    sharedStrings.set(tag.toLowerCase(), { type: 'canonical', parent: tag });
    for (const alias of entry.aliases || []) {
      sharedStrings.set(alias.toLowerCase(), { type: 'alias', parent: tag });
    }
  }
  const projectStrings = new Map();
  for (const [tag, entry] of Object.entries(projectRaw)) {
    projectStrings.set(tag.toLowerCase(), { type: 'canonical', parent: tag });
    for (const alias of entry.aliases || []) {
      projectStrings.set(alias.toLowerCase(), { type: 'alias', parent: tag });
    }
  }
  // Find collisions
  const overlaps = [];
  for (const [str, sharedInfo] of sharedStrings) {
    if (projectStrings.has(str)) {
      const projectInfo = projectStrings.get(str);
      overlaps.push({ string: str, shared: sharedInfo, project: projectInfo });
    }
  }
  return overlaps;
}

// ─── Lockfile ────────────────────────────────────────────────────────────────

function acquireLock() {
  if (existsSync(LOCK_PATH)) {
    let raw;
    try { raw = readFileSync(LOCK_PATH, 'utf-8').trim(); } catch { /* remove below */ }
    const pid = parseInt(raw, 10);
    if (!isNaN(pid)) {
      // Check /proc/<pid> — Linux-specific but matches target environment
      if (existsSync(`/proc/${pid}`)) {
        process.stderr.write(
          `Error: another indexer is running (PID ${pid}). Lock file: ${LOCK_PATH}\n`,
        );
        process.exit(1);
      }
      process.stderr.write(`Warning: removing stale lock (PID ${pid} no longer running)\n`);
    }
    try { unlinkSync(LOCK_PATH); } catch { /* best-effort */ }
  }
  writeFileSync(LOCK_PATH, String(process.pid), 'utf-8');
}

function releaseLock() {
  try { unlinkSync(LOCK_PATH); } catch { /* best-effort */ }
}

// ─── Ignore patterns (for manual .tags walk only) ───────────────────────────

function loadIgnorePatterns() {
  const patterns = ['.git'];
  if (existsSync(TAGDEXERIGNORE)) {
    for (let line of readFileSync(TAGDEXERIGNORE, 'utf-8').split('\n')) {
      line = line.trim();
      if (!line || line.startsWith('#')) continue;
      patterns.push(line.endsWith('/') ? line.slice(0, -1) : line);
    }
  }
  return patterns;
}

function dirMatchesIgnore(name, patterns) {
  for (const p of patterns) {
    if (p === name) return true;
    if (p.includes('*')) {
      const re = new RegExp('^' + p.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*') + '$');
      if (re.test(name)) return true;
    }
  }
  return false;
}

// ─── File listing via ripgrep ───────────────────────────────────────────────

function getRipgrepFiles() {
  const args = ['rg', '--files', '--no-messages'];
  if (existsSync(TAGDEXERIGNORE)) {
    args.push('--ignore-file', TAGDEXERIGNORE);
  }
  try {
    const out = execSync(args.join(' '), {
      cwd: ROOT,
      encoding: 'utf-8',
      maxBuffer: 50 * 1024 * 1024,
    });
    return out.trim().split('\n').filter(Boolean);
  } catch (err) {
    if (err.status === 1) return []; // rg exits 1 when no files matched
    throw err;
  }
}

// ─── Discover .tags files (including in gitignored dirs like data/) ─────────

function discoverTagsFiles(ignorePatterns) {
  const found = [];
  const walk = (dir) => {
    let entries;
    try { entries = readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const ent of entries) {
      if (ent.isFile() && ent.name === '.tags') {
        const rel = relative(ROOT, join(dir, '.tags'));
        found.push(rel === '.tags' ? '.tags' : rel);
      }
      if (ent.isDirectory() && !ent.isSymbolicLink() && !dirMatchesIgnore(ent.name, ignorePatterns)) {
        walk(join(dir, ent.name));
      }
    }
  };
  walk(ROOT);
  return found;
}

// ─── Full reindex ───────────────────────────────────────────────────────────

function fullReindex() {
  const { aliasMap } = loadMergedAliases();
  const rgFiles = getRipgrepFiles();
  const ignorePatterns = loadIgnorePatterns();

  // Discover .tags files from both rg output and manual walk
  const rgTagsFiles = rgFiles.filter(f => basename(f) === '.tags');
  const walkTagsFiles = discoverTagsFiles(ignorePatterns);
  const allTagsFiles = [...new Set([...rgTagsFiles, ...walkTagsFiles])];

  // index: relPath → { tags: Set, sources: Set, isFolder: bool }
  const index = new Map();
  const greylistedFolders = new Set();

  function getOrCreate(path, isFolder = false) {
    if (!index.has(path)) {
      index.set(path, { tags: new Set(), sources: new Set(), isFolder });
    }
    return index.get(path);
  }

  // Phase 1: parse all .tags files → populate index + greylist
  for (const tf of allTagsFiles) {
    const dir = tf === '.tags' ? '' : dirname(tf);
    let content;
    try { content = readFileSync(join(ROOT, tf), 'utf-8'); } catch { continue; }

    for (const entry of parseTagsFile(content, aliasMap)) {
      const fullPath = dir ? `${dir}/${entry.name}` : entry.name;
      if (entry.isFolder) greylistedFolders.add(fullPath);
      const rec = getOrCreate(fullPath, entry.isFolder);
      for (const t of entry.tags) rec.tags.add(t);
      rec.sources.add('tags-file');
    }
  }

  // Phase 2: scan headers in allowlisted, non-greylisted files
  for (const file of rgFiles) {
    if (basename(file) === '.tags') continue;
    const ext = extname(file).toLowerCase();
    if (!HEADER_EXTENSIONS.has(ext)) continue;

    // Skip files inside greylisted folders
    let grey = false;
    for (const gf of greylistedFolders) {
      if (file === gf || file.startsWith(gf + '/')) { grey = true; break; }
    }
    if (grey) continue;

    let content;
    try { content = readFileSync(join(ROOT, file), 'utf-8'); } catch { continue; }

    const tags = parseHeader(content, aliasMap);
    if (tags.length > 0) {
      const rec = getOrCreate(file);
      for (const t of tags) rec.tags.add(t);
      rec.sources.add('header');
    }
  }

  return buildOutput(index);
}

// ─── Single-file incremental reindex ────────────────────────────────────────

function singleFileReindex(targetPath) {
  const relPath = relative(ROOT, resolve(ROOT, targetPath));
  const { aliasMap } = loadMergedAliases();

  let existing;
  try { existing = JSON.parse(readFileSync(INDEX_PATH, 'utf-8')); } catch {
    // No index — fall through to full reindex
    return fullReindex();
  }

  // Remove old entry
  existing.entries = existing.entries.filter(e => e.path !== relPath);

  const absPath = join(ROOT, relPath);
  if (!existsSync(absPath)) {
    rebuildTagCounts(existing);
    return existing;
  }

  const tags = new Set();
  const sources = new Set();

  // Header scan
  const ext = extname(relPath).toLowerCase();
  if (HEADER_EXTENSIONS.has(ext)) {
    try {
      const content = readFileSync(absPath, 'utf-8');
      const htags = parseHeader(content, aliasMap);
      if (htags.length > 0) { for (const t of htags) tags.add(t); sources.add('header'); }
    } catch { /* skip */ }
  }

  // .tags companion
  const dir = dirname(relPath);
  const tagsFilePath = join(ROOT, dir === '.' ? '.tags' : join(dir, '.tags'));
  if (existsSync(tagsFilePath)) {
    try {
      const content = readFileSync(tagsFilePath, 'utf-8');
      const base = basename(relPath);
      for (const entry of parseTagsFile(content, aliasMap)) {
        if (entry.name === base && !entry.isFolder) {
          for (const t of entry.tags) tags.add(t);
          sources.add('tags-file');
        }
      }
    } catch { /* skip */ }
  }

  if (tags.size > 0) {
    let source = 'header';
    if (sources.has('header') && sources.has('tags-file')) source = 'both';
    else if (sources.has('tags-file')) source = 'tags-file';
    existing.entries.push({ path: relPath, tags: [...tags].sort(), source, isFolder: false });
  }

  existing.entries.sort((a, b) => a.path.localeCompare(b.path));
  rebuildTagCounts(existing);
  return existing;
}

// ─── Reconcile: find orphan .tags entries ───────────────────────────────────

function reconcile() {
  const { aliasMap } = loadMergedAliases();
  const ignorePatterns = loadIgnorePatterns();
  const allTagsFiles = discoverTagsFiles(ignorePatterns);
  // Also include rg-visible .tags files
  const rgFiles = getRipgrepFiles();
  const rgTags = rgFiles.filter(f => basename(f) === '.tags');
  const merged = [...new Set([...allTagsFiles, ...rgTags])];

  const orphans = [];
  for (const tf of merged) {
    const dir = tf === '.tags' ? '' : dirname(tf);
    let content;
    try { content = readFileSync(join(ROOT, tf), 'utf-8'); } catch { continue; }

    for (const entry of parseTagsFile(content, aliasMap)) {
      const fullPath = dir ? join(dir, entry.name) : entry.name;
      const absPath = join(ROOT, fullPath);
      const exists = entry.isFolder
        ? existsSync(absPath) && statSync(absPath).isDirectory()
        : existsSync(absPath);
      if (!exists) {
        orphans.push({ tagsFile: tf, name: entry.name, isFolder: entry.isFolder, tags: entry.tags });
      }
    }
  }

  if (orphans.length === 0) {
    process.stdout.write('No orphaned entries found.\n');
  } else {
    process.stdout.write(`Found ${orphans.length} orphaned .tags entries:\n`);
    for (const o of orphans) {
      const suffix = o.isFolder ? '/' : '';
      process.stdout.write(`  ${o.tagsFile}  →  ${o.name}${suffix} [${o.tags.join(', ')}]\n`);
    }
  }
}

// ─── Helpers ────────────────────────────────────────────────────────────────

function buildOutput(index) {
  const tagCounts = {};
  const entries = [];

  for (const [path, rec] of index) {
    if (rec.tags.size === 0) continue;
    const tags = [...rec.tags].sort();
    let source = 'header';
    if (rec.sources.has('header') && rec.sources.has('tags-file')) source = 'both';
    else if (rec.sources.has('tags-file')) source = 'tags-file';
    entries.push({ path, tags, source, isFolder: rec.isFolder });
    for (const t of tags) tagCounts[t] = (tagCounts[t] || 0) + 1;
  }

  entries.sort((a, b) => a.path.localeCompare(b.path));
  return { version: '0.04', lastFullReindex: new Date().toISOString(), tags: tagCounts, entries };
}

function rebuildTagCounts(indexData) {
  const counts = {};
  for (const entry of indexData.entries) {
    for (const t of entry.tags) counts[t] = (counts[t] || 0) + 1;
  }
  indexData.tags = counts;
}

function writeIndexAtomic(indexData) {
  const json = JSON.stringify(indexData, null, 2) + '\n';
  const tmp = INDEX_PATH + '.tmp.' + process.pid;
  writeFileSync(tmp, json, 'utf-8');
  renameSync(tmp, INDEX_PATH);
}

// ─── Tag writing ───────────────────────────────────────────────────────────

const COMMENT_PREFIXES = {
  '.py': '# ', '.sh': '# ', '.yaml': '# ', '.yml': '# ', '.toml': '# ',
  '.js': '// ', '.ts': '// ', '.tsx': '// ', '.jsx': '// ', '.css': '// ',
  '.md': '<!-- ', '.html': '<!-- ',
};
const COMMENT_SUFFIXES = { '.md': ' -->', '.html': ' -->' };

function addTagsToFile(filePath, tagsToAdd) {
  const { aliasMap, descriptions, canonicalTags, genericPath } = loadMergedAliases();
  const { sharedRaw, projectRaw } = loadBothRaw();
  const relPath = relative(ROOT, resolve(ROOT, filePath));
  const absPath = join(ROOT, relPath);
  const ext = extname(relPath).toLowerCase();

  // Determine write target for new tag registration
  const useGenericForNew = hasGenericFlag(process.argv);
  const newTagWritePath = useGenericForNew && genericPath ? genericPath : ALIASES_PATH;
  const newTagLabel = useGenericForNew && genericPath ? 'shared' : 'project';

  // Collision detection: check all tag strings across both files
  const allStrings = new Map(); // string → { source: 'shared'|'project', type, parent }
  for (const [tag, entry] of Object.entries(sharedRaw)) {
    allStrings.set(tag.toLowerCase(), { source: 'shared', type: 'canonical', parent: tag });
    for (const alias of entry.aliases || []) {
      allStrings.set(alias.toLowerCase(), { source: 'shared', type: 'alias', parent: tag });
    }
  }
  for (const [tag, entry] of Object.entries(projectRaw)) {
    allStrings.set(tag.toLowerCase(), { source: 'project', type: 'canonical', parent: tag });
    for (const alias of entry.aliases || []) {
      allStrings.set(alias.toLowerCase(), { source: 'project', type: 'alias', parent: tag });
    }
  }

  const resolved = tagsToAdd.map(t => {
    const n = t.trim().toLowerCase();
    const canonical = aliasMap[n];
    if (canonical && canonical !== n) {
      // Input is an alias that maps to a different canonical name
      const desc = descriptions[canonical];
      const descPart = desc ? ` (${desc})` : '';
      process.stdout.write(`'${n}' is an alias of canonical tag '${canonical}'${descPart} — adding '${canonical}'.\n`);
      return canonical;
    } else if (canonical) {
      // Input is already the canonical tag (aliasMap maps canonical→canonical)
      return canonical;
    } else {
      // Unknown tag — auto-register to project (or shared with --generic)
      process.stdout.write(`'${n}' is new. Registering in ${newTagLabel} aliases and adding to file header.\n`);
      // Register it
      let targetRaw;
      try { targetRaw = JSON.parse(readFileSync(newTagWritePath, 'utf-8')); } catch { targetRaw = {}; }
      if (!targetRaw[n]) {
        targetRaw[n] = { aliases: [], description: '' };
        writeAliasesAtomic(targetRaw, newTagWritePath);
      }
      return n;
    }
  });

  if (HEADER_EXTENSIONS.has(ext)) {
    // Header-taggable file
    const content = readFileSync(absPath, 'utf-8');
    const existing = parseHeader(content, aliasMap);
    const merged = [...new Set([...existing, ...resolved])].sort();
    const prefix = COMMENT_PREFIXES[ext] || '# ';
    const suffix = COMMENT_SUFFIXES[ext] || '';
    const tagLine = `${prefix}@tagdex: ${merged.join(', ')}${suffix}`;

    const lines = content.split('\n');
    let replaced = false;
    for (let i = 0; i < Math.min(lines.length, 20); i++) {
      if (HEADER_MARKER_RE.test(lines[i])) {
        lines[i] = tagLine;
        replaced = true;
        break;
      }
    }
    if (!replaced) {
      // Insert after shebang if present, else at line 0
      const insertAt = lines[0]?.startsWith('#!') ? 1 : 0;
      lines.splice(insertAt, 0, tagLine);
    }
    const tmp = absPath + '.tmp.' + process.pid;
    writeFileSync(tmp, lines.join('\n'), 'utf-8');
    renameSync(tmp, absPath);
  } else {
    // Use .tags companion file
    const dir = dirname(absPath);
    const tagsFile = join(dir, '.tags');
    const name = basename(relPath);
    let content = '';
    try { content = readFileSync(tagsFile, 'utf-8'); } catch { /* new file */ }

    const existingTags = [];
    const otherLines = [];
    for (const line of content.split('\n')) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) { otherLines.push(line); continue; }
      const colonIdx = trimmed.indexOf(':');
      if (colonIdx === -1) { otherLines.push(line); continue; }
      const rawName = trimmed.slice(0, colonIdx).trim();
      if (rawName === name) {
        const tagStr = trimmed.slice(colonIdx + 1).trim();
        existingTags.push(...parseTags(tagStr, aliasMap));
      } else {
        otherLines.push(line);
      }
    }
    const merged = [...new Set([...existingTags, ...resolved])].sort();
    otherLines.push(`${name}: ${merged.join(', ')}`);
    const tmp = tagsFile + '.tmp.' + process.pid;
    writeFileSync(tmp, otherLines.filter(l => l !== undefined).join('\n') + '\n', 'utf-8');
    renameSync(tmp, tagsFile);
  }
  process.stdout.write(`Tagged ${relPath}: ${resolved.join(', ')}\n`);
}

function removeTagsFromFile(filePath, tagsToRemove) {
  const { aliasMap, descriptions, canonicalTags } = loadMergedAliases();
  const relPath = relative(ROOT, resolve(ROOT, filePath));
  const absPath = join(ROOT, relPath);
  const ext = extname(relPath).toLowerCase();
  const resolved = tagsToRemove.map(t => {
    const n = t.trim().toLowerCase();
    const canonical = aliasMap[n];
    if (canonical && canonical !== n) {
      const desc = descriptions[canonical];
      const descPart = desc ? ` (${desc})` : '';
      process.stdout.write(`'${n}' is an alias of canonical tag '${canonical}'${descPart} — removing '${canonical}'.\n`);
      return canonical;
    } else if (canonical) {
      return canonical;
    } else {
      process.stdout.write(`'${n}' is not in aliases.json. Removing as-is. Run --define-tag to register it.\n`);
      return n;
    }
  });

  if (HEADER_EXTENSIONS.has(ext)) {
    const content = readFileSync(absPath, 'utf-8');
    const existing = parseHeader(content, aliasMap);
    const remaining = existing.filter(t => !resolved.includes(t));
    const lines = content.split('\n');

    for (let i = 0; i < Math.min(lines.length, 20); i++) {
      if (HEADER_MARKER_RE.test(lines[i])) {
        if (remaining.length === 0) {
          lines.splice(i, 1);
        } else {
          const prefix = COMMENT_PREFIXES[ext] || '# ';
          const suffix = COMMENT_SUFFIXES[ext] || '';
          lines[i] = `${prefix}@tagdex: ${remaining.join(', ')}${suffix}`;
        }
        break;
      }
    }
    const tmp = absPath + '.tmp.' + process.pid;
    writeFileSync(tmp, lines.join('\n'), 'utf-8');
    renameSync(tmp, absPath);
  } else {
    const dir = dirname(absPath);
    const tagsFile = join(dir, '.tags');
    const name = basename(relPath);
    let content = '';
    try { content = readFileSync(tagsFile, 'utf-8'); } catch { return; }

    const newLines = [];
    for (const line of content.split('\n')) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith('#')) { newLines.push(line); continue; }
      const colonIdx = trimmed.indexOf(':');
      if (colonIdx === -1) { newLines.push(line); continue; }
      const rawName = trimmed.slice(0, colonIdx).trim();
      if (rawName === name) {
        const tagStr = trimmed.slice(colonIdx + 1).trim();
        const existing = parseTags(tagStr, aliasMap);
        const remaining = existing.filter(t => !resolved.includes(t));
        if (remaining.length > 0) {
          newLines.push(`${name}: ${remaining.join(', ')}`);
        }
        // else: remove the line entirely
      } else {
        newLines.push(line);
      }
    }
    const tmp = tagsFile + '.tmp.' + process.pid;
    writeFileSync(tmp, newLines.join('\n') + '\n', 'utf-8');
    renameSync(tmp, tagsFile);
  }
  process.stdout.write(`Removed from ${relPath}: ${resolved.join(', ')}\n`);
}

// ─── Search ────────────────────────────────────────────────────────────────

function searchTags(queryStr) {
  if (!existsSync(INDEX_PATH)) {
    process.stderr.write('Error: .tagindex.json not found. Run a full reindex first.\n');
    process.exit(1);
  }
  const index = JSON.parse(readFileSync(INDEX_PATH, 'utf-8'));
  const { aliasMap } = loadMergedAliases();

  const parts = queryStr.split(',').map(s => s.trim()).filter(Boolean);
  const include = [];
  const exclude = [];
  for (const p of parts) {
    if (p.startsWith('-')) {
      const tag = p.slice(1).trim();
      if (tag) exclude.push(resolveTag(tag, aliasMap));
    } else {
      include.push(resolveTag(p, aliasMap));
    }
  }

  const results = index.entries.filter(e => {
    if (include.length > 0 && !include.every(t => e.tags.includes(t))) return false;
    if (exclude.length > 0 && exclude.some(t => e.tags.includes(t))) return false;
    return true;
  });

  if (results.length === 0) {
    process.stdout.write('No matching files.\n');
  } else {
    for (const e of results) {
      process.stdout.write(`${e.path.padEnd(50)} ${e.tags.join(', ')}\n`);
    }
    process.stdout.write(`\n${results.length} file(s) matched.\n`);
  }
}

// ─── List tags ─────────────────────────────────────────────────────────────

function listTags() {
  const { canonicalTags, descriptions, sharedTags, projectTags } = loadMergedAliases();
  const { sharedRaw, projectRaw } = loadBothRaw();
  const raw = { ...sharedRaw, ...projectRaw };

  if (canonicalTags.length === 0) {
    process.stdout.write('No tags defined in aliases.json.\n');
    return;
  }

  for (const tag of canonicalTags) {
    const entry = raw[tag] || {};
    const aliases = (entry.aliases || []).join(', ');
    const desc = descriptions[tag] || '';
    const source = sharedRaw[tag] && projectRaw[tag] ? '[shared+project]'
      : sharedRaw[tag] ? '[shared]' : '[project]';
    process.stdout.write(`${tag.padEnd(25)} ${source.padEnd(17)} [${aliases}]  ${desc}\n`);
  }
  process.stdout.write(`\n${canonicalTags.length} tag(s) total.\n`);

  // Overlap detection
  const overlaps = detectOverlaps(sharedRaw, projectRaw);
  if (overlaps.length > 0) {
    process.stdout.write(`\n⚠ Conflicts: ${overlaps.length} string(s) appear in both shared and project files:\n`);
    for (const o of overlaps) {
      const sharedLabel = o.shared.type === 'canonical'
        ? `canonical "${o.shared.parent}"`
        : `alias of "${o.shared.parent}"`;
      const projectLabel = o.project.type === 'canonical'
        ? `canonical "${o.project.parent}"`
        : `alias of "${o.project.parent}"`;
      process.stdout.write(`  "${o.string}" — shared: ${sharedLabel}, project: ${projectLabel}\n`);
    }
    process.stdout.write(`\nRun --merge to resolve conflicts.\n`);
  }
}

// ─── Define tag ────────────────────────────────────────────────────────────

function defineTag(args) {
  // Parse subcommand arguments
  const idx = args.indexOf('--define-tag');
  const remaining = args.slice(idx + 1);

  if (remaining.length === 0) {
    process.stderr.write(`Error: --define-tag requires arguments.

Usage:
  --define-tag TAG                                  Show current definition
  --define-tag TAG --description "DESC"             Set description
  --define-tag TAG --add-alias ALIAS                Add alias
  --define-tag TAG --remove-alias ALIAS             Remove alias
  --define-tag TAG --promote ALIAS                  Promote alias to canonical (demote current)
  --define-tag TAG --create --description "DESC" [--add-alias A1 --add-alias A2]
                                                    Create new tag entry

All writes require owner approval. Pass --yes to skip confirmation.
Pass --generic to write to the shared aliases file.
`);
    process.exit(1);
  }

  const tagName = remaining[0];
  if (tagName.startsWith('-')) {
    process.stderr.write(`Error: first argument to --define-tag must be a tag name, got "${tagName}"\n`);
    process.exit(1);
  }

  // Determine write target: project by default, shared with --generic flag
  const genericPath = findGenericPath(args);
  const useGeneric = hasGenericFlag(remaining) && genericPath;
  const writePath = useGeneric ? genericPath : ALIASES_PATH;

  let raw;
  try { raw = JSON.parse(readFileSync(writePath, 'utf-8')); } catch { raw = {}; }

  const hasCreate = remaining.includes('--create');
  const hasYes = remaining.includes('--yes');

  // Collect --description
  const descIdx = remaining.indexOf('--description');
  const newDesc = descIdx !== -1 ? remaining[descIdx + 1] : null;

  // Collect all --add-alias
  const addAliases = [];
  for (let i = 0; i < remaining.length; i++) {
    if (remaining[i] === '--add-alias' && remaining[i + 1]) {
      addAliases.push(remaining[i + 1].toLowerCase());
    }
  }

  // Collect --remove-alias
  const removeAliases = [];
  for (let i = 0; i < remaining.length; i++) {
    if (remaining[i] === '--remove-alias' && remaining[i + 1]) {
      removeAliases.push(remaining[i + 1].toLowerCase());
    }
  }

  // Collect --promote
  const promoteIdx = remaining.indexOf('--promote');
  const promoteAlias = promoteIdx !== -1 ? remaining[promoteIdx + 1] : null;

  // If no action flags, just show current definition (reads from BOTH files)
  if (!hasCreate && !newDesc && addAliases.length === 0 && removeAliases.length === 0 && !promoteAlias) {
    const { sharedRaw, projectRaw } = loadBothRaw();
    const mergedRaw = { ...sharedRaw, ...projectRaw };
    const { aliasMap } = loadMergedAliases();

    if (!mergedRaw[tagName]) {
      // Check if it's an alias
      const resolved = aliasMap[tagName.toLowerCase()];
      if (resolved && mergedRaw[resolved]) {
        process.stdout.write(`"${tagName}" is an alias for canonical tag "${resolved}".\n`);
        const source = sharedRaw[resolved] ? 'shared' : 'project';
        showTagDef(resolved, mergedRaw[resolved], source);
      } else {
        process.stdout.write(`Tag "${tagName}" not found in shared or project aliases.\n`);
      }
    } else {
      const source = sharedRaw[tagName] && projectRaw[tagName] ? 'shared+project'
        : sharedRaw[tagName] ? 'shared' : 'project';
      showTagDef(tagName, mergedRaw[tagName], source);
    }
    return;
  }

  // Create new entry
  if (hasCreate) {
    if (raw[tagName]) {
      process.stderr.write(`Error: tag "${tagName}" already exists. Use --description / --add-alias to modify.\n`);
      process.exit(1);
    }
    // Check for conflicts with existing aliases
    const { aliasMap } = loadMergedAliases();
    const conflict = aliasMap[tagName.toLowerCase()];
    if (conflict) {
      process.stderr.write(`Error: "${tagName}" is already an alias for canonical tag "${conflict}". Resolve this first.\n`);
      process.exit(1);
    }
    for (const a of addAliases) {
      const ac = aliasMap[a];
      if (ac) {
        process.stderr.write(`Error: alias "${a}" is already mapped to canonical tag "${ac}". Resolve this first.\n`);
        process.exit(1);
      }
    }

    raw[tagName] = {
      aliases: addAliases,
      description: newDesc || '',
    };
    if (!hasYes) {
      process.stdout.write(`Will create tag "${tagName}" with description "${newDesc || ''}" and aliases [${addAliases.join(', ')}].\n`);
      process.stdout.write('Pass --yes to confirm, or re-run with --yes.\n');
      process.exit(0);
    }
    writeAliasesAtomic(raw, writePath);
    process.stdout.write(`Created tag "${tagName}"${useGeneric ? ' (shared)' : ' (project)'}.\n`);
    return;
  }

  // Modify existing entry
  if (!raw[tagName]) {
    process.stderr.write(`Error: tag "${tagName}" not found. Use --create to add it.\n`);
    process.exit(1);
  }

  const changes = [];

  if (newDesc !== null) {
    changes.push(`description: "${raw[tagName].description}" → "${newDesc}"`);
    raw[tagName].description = newDesc;
  }

  for (const a of addAliases) {
    // Check conflicts
    const { aliasMap } = loadMergedAliases();
    const conflict = aliasMap[a];
    if (conflict && conflict !== tagName) {
      process.stderr.write(`Error: alias "${a}" is already mapped to "${conflict}". Resolve conflict first.\n`);
      process.exit(1);
    }
    if (!raw[tagName].aliases.includes(a)) {
      raw[tagName].aliases.push(a);
      changes.push(`+alias "${a}"`);
    }
  }

  for (const a of removeAliases) {
    const idx = raw[tagName].aliases.indexOf(a);
    if (idx !== -1) {
      raw[tagName].aliases.splice(idx, 1);
      changes.push(`-alias "${a}"`);
    }
  }

  if (promoteAlias) {
    const pa = promoteAlias.toLowerCase();
    if (!raw[tagName].aliases.includes(pa) && pa !== tagName.toLowerCase()) {
      process.stderr.write(`Error: "${promoteAlias}" is not an alias of "${tagName}".\n`);
      process.exit(1);
    }
    // Promote: rename the entry
    const entry = raw[tagName];
    // Demote current canonical to alias
    entry.aliases = entry.aliases.filter(a => a !== pa);
    entry.aliases.push(tagName.toLowerCase());
    // Remove duplicates
    entry.aliases = [...new Set(entry.aliases)].filter(a => a !== pa);
    delete raw[tagName];
    raw[pa] = entry;
    changes.push(`promoted "${pa}" to canonical (demoted "${tagName}" to alias)`);
  }

  if (changes.length === 0) {
    process.stdout.write('No changes to make.\n');
    return;
  }

  if (!hasYes) {
    process.stdout.write(`Changes to "${tagName}":\n`);
    for (const c of changes) process.stdout.write(`  ${c}\n`);
    process.stdout.write('Pass --yes to confirm.\n');
    process.exit(0);
  }

  writeAliasesAtomic(raw, writePath);
  process.stdout.write(`Updated "${tagName}"${useGeneric ? ' (shared)' : ' (project)'}: ${changes.join(', ')}\n`);
}

function showTagDef(tag, entry, source) {
  process.stdout.write(`Tag: ${tag}\n`);
  if (source) process.stdout.write(`Source: ${source}\n`);
  process.stdout.write(`Description: ${entry.description || '(none)'}\n`);
  process.stdout.write(`Aliases: ${(entry.aliases || []).join(', ') || '(none)'}\n`);
}

function writeAliasesAtomic(data, targetPath) {
  const dest = targetPath || ALIASES_PATH;
  const json = JSON.stringify(data, null, 2) + '\n';
  const tmp = dest + '.tmp.' + process.pid;
  writeFileSync(tmp, json, 'utf-8');
  renameSync(tmp, dest);
}

// ─── Merge command ─────────────────────────────────────────────────────────

function mergeCommand() {
  const genericPath = findGenericPath(process.argv);
  if (!genericPath) {
    process.stderr.write('Error: --merge requires shared aliases path. Set genericPath in .tagdexerrc or pass --generic.\n');
    process.exit(1);
  }
  const { sharedRaw, projectRaw } = loadBothRaw();

  // Check for existing merge JSON
  const existingMerge = findMergeJson();
  if (existingMerge) {
    // Phase 2: apply edits from merge JSON
    applyMerge(existingMerge, genericPath);
    return;
  }

  // Phase 1: generate merge JSON
  const overlaps = detectOverlaps(sharedRaw, projectRaw);
  if (overlaps.length === 0) {
    process.stdout.write('No conflicts found between shared and project aliases.\n');
    return;
  }

  const mergeData = {
    generated: new Date().toISOString(),
    sharedPath: genericPath,
    projectPath: ALIASES_PATH,
    conflicts: overlaps.map(o => ({
      string: o.string,
      shared: { type: o.shared.type, parent: o.shared.parent },
      project: { type: o.project.type, parent: o.project.parent },
      resolution: 'skip', // 'merge-shared', 'merge-project', 'skip'
    })),
  };

  const mergeFile = join(ROOT, `tagdexer-merge_${randomUUID()}.json`);
  writeFileSync(mergeFile, JSON.stringify(mergeData, null, 2) + '\n', 'utf-8');
  process.stdout.write(`Generated merge file: ${relative(ROOT, mergeFile)}\n`);
  process.stdout.write(`${overlaps.length} conflict(s) found.\n`);
  process.stdout.write(`\nEdit the file and set "resolution" for each conflict to:\n`);
  process.stdout.write(`  "merge-shared"  — keep in shared, remove from project\n`);
  process.stdout.write(`  "merge-project" — keep in project, remove from shared\n`);
  process.stdout.write(`  "skip"          — leave as-is\n`);
  process.stdout.write(`\nThen re-run --merge to apply.\n`);
}

function findMergeJson() {
  const entries = readdirSync(ROOT);
  for (const e of entries) {
    if (e.startsWith('tagdexer-merge_') && e.endsWith('.json')) {
      const full = join(ROOT, e);
      try {
        const data = JSON.parse(readFileSync(full, 'utf-8'));
        if (data.conflicts && Array.isArray(data.conflicts)) return full;
      } catch { /* not valid */ }
    }
  }
  return null;
}

function applyMerge(mergeFile, genericPath) {
  const mergeData = JSON.parse(readFileSync(mergeFile, 'utf-8'));
  let sharedRaw, projectRaw;
  try { sharedRaw = JSON.parse(readFileSync(genericPath, 'utf-8')); } catch { sharedRaw = {}; }
  try { projectRaw = JSON.parse(readFileSync(ALIASES_PATH, 'utf-8')); } catch { projectRaw = {}; }

  let applied = 0;
  let skipped = 0;

  for (const conflict of mergeData.conflicts) {
    if (conflict.resolution === 'skip' || !conflict.resolution) {
      skipped++;
      continue;
    }

    const str = conflict.string;

    if (conflict.resolution === 'merge-shared') {
      // Keep in shared, remove from project
      removeStringFromRaw(projectRaw, str, conflict.project);
      applied++;
    } else if (conflict.resolution === 'merge-project') {
      // Keep in project, remove from shared
      removeStringFromRaw(sharedRaw, str, conflict.shared);
      applied++;
    } else {
      skipped++;
    }
  }

  if (applied > 0) {
    writeAliasesAtomic(sharedRaw, genericPath);
    writeAliasesAtomic(projectRaw, ALIASES_PATH);
  }

  process.stdout.write(`Merge applied: ${applied} resolved, ${skipped} skipped.\n`);
  if (applied > 0) {
    process.stdout.write(`Both alias files updated. Run --merge-cleanup to remove the merge file.\n`);
  }
}

function removeStringFromRaw(raw, str, info) {
  const strLower = str.toLowerCase();
  if (info.type === 'canonical') {
    // Remove the entire tag entry
    delete raw[info.parent];
  } else {
    // Remove alias from parent
    if (raw[info.parent] && Array.isArray(raw[info.parent].aliases)) {
      raw[info.parent].aliases = raw[info.parent].aliases.filter(a => a.toLowerCase() !== strLower);
    }
  }
}

function mergeCleanup() {
  const entries = readdirSync(ROOT);
  let removed = 0;
  for (const e of entries) {
    if (e.startsWith('tagdexer-merge_') && e.endsWith('.json')) {
      unlinkSync(join(ROOT, e));
      removed++;
    }
  }
  if (removed > 0) {
    process.stdout.write(`Removed ${removed} merge file(s).\n`);
  } else {
    process.stdout.write('No merge files to clean up.\n');
  }
}

// ─── Config loading (same pattern as tracker.js) ────────────────────────────

function findConfigPath() {
  const local = join(TAGDEXER_DIR, 'trackdexer.config.json');
  if (existsSync(local)) return local;
  const rcPath = join(ROOT, '.tagdexerrc');
  if (existsSync(rcPath)) {
    const lines = readFileSync(rcPath, 'utf-8').split('\n');
    for (const line of lines) {
      const m = line.match(/^\s*(?:genericPath|canonicalPath)\s*=\s*(.+)/);
      if (m) {
        const p = resolve(m[1].trim());
        const configPath = join(p, 'trackdexer.config.json');
        if (existsSync(configPath)) return configPath;
      }
    }
  }
  return null;
}

function loadConfig() {
  const configPath = findConfigPath();
  if (!configPath) return null;
  try {
    return JSON.parse(readFileSync(configPath, 'utf-8'));
  } catch {
    return null;
  }
}

// ─── CLI ────────────────────────────────────────────────────────────────────

function printHelp() {
  const config = loadConfig();
  const h = config && config.indexerHelp;

  if (h) {
    let out = `tagdexer v0.04 — tag-based file indexer\n\n${h.usage}\n\n${h.defineTagSubcommands}\n\n${h.sharedAliasResolution}\n\n${h.tagClassification}\n`;
    if (h.searchExamples) out += `\n${h.searchExamples}\n`;
    out += `\n${h.footer}\n`;
    process.stdout.write(out);
    return;
  }

  process.stdout.write(
    `tagdexer v0.04 — tag-based file indexer

Usage:
  node tagdexer/indexer.js                          Full reindex from CWD
  node tagdexer/indexer.js --file PATH              Incremental: rescan one file
  node tagdexer/indexer.js --add-tag FILE TAG1,TAG2 Add tags to a file
  node tagdexer/indexer.js --remove-tag FILE TAG1   Remove tags from a file
  node tagdexer/indexer.js --reconcile              Detect orphaned .tags entries
  node tagdexer/indexer.js --search "tag1,tag2,-tag3"
                                                    Search by tags (- prefix excludes)
  node tagdexer/indexer.js --list-tags              List all tags with descriptions
  node tagdexer/indexer.js --define-tag TAG [opts]  View or modify a tag definition
  node tagdexer/indexer.js --merge                  Detect/resolve shared+project conflicts
  node tagdexer/indexer.js --merge-cleanup          Remove merge JSON after resolution
  node tagdexer/indexer.js --help                   Show this help

--define-tag subcommands:
  --define-tag TAG                                  Show definition (both files)
  --define-tag TAG --description "DESC"             Set description
  --define-tag TAG --add-alias ALIAS                Add alias (repeatable)
  --define-tag TAG --remove-alias ALIAS             Remove alias (repeatable)
  --define-tag TAG --promote ALIAS                  Promote alias to canonical
  --define-tag TAG --create --description "DESC"    Create new tag entry
  Add --yes to confirm writes. Add --generic to write to shared aliases.

Shared alias resolution:
  --generic /path/to/tagdexer     Use shared aliases from this path
  .tagdexerrc at repo root        genericPath=/path/to/tagdexer

Tag classification:
  New tags from --add-tag are written to project aliases by default.
  Pass --generic to write new tags to the shared aliases file instead.

Exit codes: 0 = success, non-zero = failure (reason on stderr).
Requires: ripgrep (rg) on PATH.
`,
  );
}

function main() {
  const args = process.argv.slice(2);

  if (args.includes('--help') || args.includes('-h')) {
    printHelp();
    process.exit(0);
  }

  if (args.includes('--reconcile')) {
    reconcile();
    process.exit(0);
  }

  const searchIdx = args.indexOf('--search');
  if (searchIdx !== -1) {
    const query = args[searchIdx + 1];
    if (!query) {
      process.stderr.write('Error: --search requires a tag query string (e.g. "tag1,tag2,-tag3")\n');
      process.exit(1);
    }
    searchTags(query);
    process.exit(0);
  }

  if (args.includes('--list-tags')) {
    listTags();
    process.exit(0);
  }

  if (args.includes('--merge-cleanup')) {
    mergeCleanup();
    process.exit(0);
  }

  if (args.includes('--merge')) {
    mergeCommand();
    process.exit(0);
  }

  if (args.includes('--define-tag')) {
    defineTag(args);
    process.exit(0);
  }

  const addTagIdx = args.indexOf('--add-tag');
  if (addTagIdx !== -1) {
    const file = args[addTagIdx + 1];
    const tags = args[addTagIdx + 2];
    if (!file || !tags) {
      process.stderr.write('Error: --add-tag requires FILE and TAG1,TAG2 arguments\n');
      process.exit(1);
    }
    addTagsToFile(file, tags.split(','));
    // Reindex after tagging
    try {
      acquireLock();
      writeIndexAtomic(fullReindex());
      releaseLock();
    } catch (err) {
      releaseLock();
      process.stderr.write(`Reindex error: ${err.message}\n`);
    }
    process.exit(0);
  }

  const removeTagIdx = args.indexOf('--remove-tag');
  if (removeTagIdx !== -1) {
    const file = args[removeTagIdx + 1];
    const tags = args[removeTagIdx + 2];
    if (!file || !tags) {
      process.stderr.write('Error: --remove-tag requires FILE and TAG1,TAG2 arguments\n');
      process.exit(1);
    }
    removeTagsFromFile(file, tags.split(','));
    try {
      acquireLock();
      writeIndexAtomic(fullReindex());
      releaseLock();
    } catch (err) {
      releaseLock();
      process.stderr.write(`Reindex error: ${err.message}\n`);
    }
    process.exit(0);
  }

  const fileIdx = args.indexOf('--file');

  try {
    acquireLock();

    let indexData;
    if (fileIdx !== -1) {
      const target = args[fileIdx + 1];
      if (!target) {
        process.stderr.write('Error: --file requires a path argument\n');
        releaseLock();
        process.exit(1);
      }
      indexData = singleFileReindex(target);
    } else {
      indexData = fullReindex();
    }

    writeIndexAtomic(indexData);
    releaseLock();
  } catch (err) {
    releaseLock();
    process.stderr.write(`Error: ${err.message}\n`);
    process.exit(1);
  }
}

main();
