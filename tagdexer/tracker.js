#!/usr/bin/env node
// tracker.js — trackdexer: append-only architectural decision log CLI
// @tagdex: tool, core, active
//
// Usage:
//   node tagdexer/tracker.js --help
//   node tagdexer/tracker.js --search [filters]
//   node tagdexer/tracker.js --add --decision "..." --intent "..." ...
//   node tagdexer/tracker.js --validate
//
// Exit codes: 0 = success, non-zero = failure (reason on stderr).

import {
  readFileSync, writeFileSync, renameSync, existsSync,
} from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadAliases, resolveTag } from './shared/core.js';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const ROOT = process.cwd();
const TAGDEXER_DIR = __dirname;
const ALIASES_PATH = join(TAGDEXER_DIR, 'aliases.json');
const DECISIONS_PATH = join(TAGDEXER_DIR, 'decisions.jsonl');
const SCHEMA_PATH = join(TAGDEXER_DIR, 'decisions.schema.json');
// Config lives at the tagdexer SOURCE repo, not in deployed copies.
// CLI finds it via .tagdexerrc genericPath → source repo → trackdexer.config.json
function findConfigPath() {
  // First check if config exists alongside this script (source repo case)
  const local = join(TAGDEXER_DIR, 'trackdexer.config.json');
  if (existsSync(local)) return local;
  // Otherwise find source repo via .tagdexerrc
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

// ─── Shared alias resolution (same pattern as indexer.js) ──────────────────

function findGenericPath() {
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

function loadMergedAliases() {
  const genericPath = findGenericPath();
  let shared = { aliasMap: {}, descriptions: {}, canonicalTags: [] };
  if (genericPath && genericPath !== ALIASES_PATH) {
    try { shared = loadAliases(genericPath); } catch { /* fallback */ }
  }
  let project = { aliasMap: {}, descriptions: {}, canonicalTags: [] };
  try { project = loadAliases(ALIASES_PATH); } catch { /* empty */ }
  return {
    aliasMap: { ...shared.aliasMap, ...project.aliasMap },
    canonicalTags: [...new Set([...shared.canonicalTags, ...project.canonicalTags])].sort(),
  };
}

// ─── Config loading ───────────────────────────────────────────────────────

function loadConfig() {
  const configPath = findConfigPath();
  if (!configPath) return null;
  try {
    return JSON.parse(readFileSync(configPath, 'utf-8'));
  } catch {
    return null;
  }
}

// ─── Schema loading and validation ─────────────────────────────────────────

function loadSchema() {
  return JSON.parse(readFileSync(SCHEMA_PATH, 'utf-8'));
}

function validateEntry(entry, schema) {
  const errors = [];

  if (typeof entry !== 'object' || entry === null || Array.isArray(entry)) {
    return ['entry is not a JSON object'];
  }

  for (const field of schema.required) {
    if (!(field in entry)) {
      errors.push(`missing required field: ${field}`);
    }
  }

  for (const key of Object.keys(entry)) {
    if (!(key in schema.properties)) {
      errors.push(`unknown field: ${key}`);
    }
  }

  for (const [key, value] of Object.entries(entry)) {
    if (!(key in schema.properties)) continue;
    const prop = schema.properties[key];

    if (prop.type === 'integer') {
      if (!Number.isInteger(value)) errors.push(`${key}: expected integer, got ${typeof value}`);
    } else if (prop.type === 'string') {
      if (typeof value !== 'string') {
        errors.push(`${key}: expected string, got ${typeof value}`);
      } else if (prop.pattern && !new RegExp(prop.pattern).test(value)) {
        errors.push(`${key}: does not match pattern ${prop.pattern}`);
      }
    } else if (prop.type === 'array') {
      if (!Array.isArray(value)) {
        errors.push(`${key}: expected array, got ${typeof value}`);
      } else if (prop.items) {
        for (let i = 0; i < value.length; i++) {
          const item = value[i];
          if (prop.items.type === 'string') {
            if (typeof item !== 'string') errors.push(`${key}[${i}]: expected string`);
          } else if (prop.items.type === 'object') {
            if (typeof item !== 'object' || item === null || Array.isArray(item)) {
              errors.push(`${key}[${i}]: expected object`);
              continue;
            }
            if (prop.items.required) {
              for (const req of prop.items.required) {
                if (!(req in item)) errors.push(`${key}[${i}]: missing required field: ${req}`);
              }
            }
            if (prop.items.properties) {
              for (const [ik, iv] of Object.entries(item)) {
                if (!(ik in prop.items.properties)) {
                  errors.push(`${key}[${i}]: unknown field: ${ik}`);
                }
                const iprop = prop.items.properties[ik];
                if (iprop && iprop.type === 'string' && typeof iv !== 'string') {
                  errors.push(`${key}[${i}].${ik}: expected string`);
                }
              }
            }
          }
        }
      }
    }
  }

  return errors;
}

// ─── JSONL I/O ─────────────────────────────────────────────────────────────

function readEntries() {
  if (!existsSync(DECISIONS_PATH)) return [];
  const content = readFileSync(DECISIONS_PATH, 'utf-8').trim();
  if (!content) return [];
  return content.split('\n').filter(l => l.trim()).map(line => {
    try { return JSON.parse(line); } catch { return null; }
  }).filter(Boolean);
}

function appendEntryAtomic(entry) {
  const entries = readEntries();
  entries.push(entry);
  entries.sort((a, b) => (a.date || '').localeCompare(b.date || '') || (a.id || 0) - (b.id || 0));
  const content = entries.map(e => JSON.stringify(e)).join('\n') + '\n';
  const tmp = DECISIONS_PATH + '.tmp.' + process.pid;
  writeFileSync(tmp, content, 'utf-8');
  renameSync(tmp, DECISIONS_PATH);
}

// ─── Commands ──────────────────────────────────────────────────────────────

function printHelp() {
  const schema = loadSchema();
  const config = loadConfig();

  if (!config) {
    // Fallback to hardcoded help when no config
    process.stdout.write(`trackdexer — append-only architectural decision log

Schema:
${JSON.stringify(schema, null, 2)}

Usage:
  node tracker.js --help
  node tracker.js --search [filters]
  node tracker.js --add [flags]
  node tracker.js --validate

Search filters (stackable, AND logic):
  --tag TAG           Filter by canonical tag (alias-resolved)
  --date YYYY-MM-DD   Exact date match
  --date YYYY-MM      Month range match
  --file PATH         Entries where files_affected contains substring
  --text KEYWORD      Case-insensitive free text across all string fields
  --fields F1,F2      Control which fields display (default: all)

Add flags:
  Required:
    --decision "..."        The architectural decision
    --intent "..."          Why this decision matters
    --context "..."         Surrounding context
    --tags "tag1,tag2"      Comma-separated tags (alias-resolved)
    --files "path1,path2"   Comma-separated relative paths from repo root
  Optional:
    --date "YYYY-MM-DD"     Date (default: today)
    --commits "hash1,hash2" Comma-separated commit hashes
    --constraints "..."     Constraints that influenced the decision
    --consequence "..."     Expected or observed consequences
    --alternative "opt|reason"  Rejected alternative (repeatable, pipe-separated)

Examples:
  node tracker.js --search --tag core --date 2026-05
  node tracker.js --search --text "atomic" --fields id,decision,intent
  node tracker.js --add --decision "Use ESM modules" --intent "Consistency" --context "Setup" --tags "core,config" --files "package.json"
  node tracker.js --validate
`);
    return;
  }

  // Config-driven help
  let out = `trackdexer — append-only architectural decision log

Schema:
${JSON.stringify(schema, null, 2)}

`;

  for (const [typeName, typeDef] of Object.entries(config.entryTypes)) {
    out += `Entry type: ${typeName} — ${typeDef.label}\n`;
    out += `  ${'Field'.padEnd(25)} ${'Requirement'.padEnd(12)} Heuristic\n`;
    out += `  ${'─'.repeat(25)} ${'─'.repeat(12)} ${'─'.repeat(40)}\n`;
    for (const [field, fieldDef] of Object.entries(typeDef.fields)) {
      out += `  ${field.padEnd(25)} ${fieldDef.requirement.padEnd(12)} ${fieldDef.heuristic}\n`;
    }
    if (typeDef.examples) {
      if (typeDef.examples.good && typeDef.examples.good.length > 0) {
        out += `\n  Good examples:\n`;
        for (const ex of typeDef.examples.good) out += `    ${ex}\n`;
      }
      if (typeDef.examples.bad && typeDef.examples.bad.length > 0) {
        out += `\n  Bad examples:\n`;
        for (const ex of typeDef.examples.bad) out += `    ${ex}\n`;
      }
    }
    out += '\n';
  }

  out += `Usage:
  node tracker.js --help
  node tracker.js --search [filters]
  node tracker.js --add [flags]
  node tracker.js --validate

Search filters (stackable, AND logic):
  --tag TAG           Filter by canonical tag (alias-resolved)
  --date YYYY-MM-DD   Exact date match
  --date YYYY-MM      Month range match
  --file PATH         Entries where files_affected contains substring
  --text KEYWORD      Case-insensitive free text across all string fields
  --fields F1,F2      Control which fields display (default: all)

Add flags:
  --type TYPE              Entry type (default: decision)
  --decision "..."         The decision or finding
  --intent "..."           Why this matters
  --context "..."          Surrounding context
  --tags "tag1,tag2"       Comma-separated tags (alias-resolved)
  --files "path1,path2"    Comma-separated relative paths from repo root
  --date "YYYY-MM-DD"      Date (default: today)
  --commits "hash1,hash2"  Comma-separated commit hashes
  --constraints "..."      Constraints that influenced the decision
  --consequence "..."      Expected or observed consequences
  --alternative "opt|reason"  Rejected alternative (repeatable, pipe-separated)
  --supersedes "ID1,ID2"   Comma-separated IDs of entries this one replaces
`;

  process.stdout.write(out);
}

function search(args) {
  const { aliasMap } = loadMergedAliases();

  // Parse filters
  const filters = { tags: [], dates: [], files: [], texts: [] };
  let fields = null;

  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--tag' && args[i + 1]) {
      filters.tags.push(resolveTag(args[i + 1], aliasMap));
      i++;
    } else if (args[i] === '--date' && args[i + 1]) {
      filters.dates.push(args[i + 1]);
      i++;
    } else if (args[i] === '--file' && args[i + 1]) {
      filters.files.push(args[i + 1]);
      i++;
    } else if (args[i] === '--text' && args[i + 1]) {
      filters.texts.push(args[i + 1].toLowerCase());
      i++;
    } else if (args[i] === '--fields' && args[i + 1]) {
      fields = args[i + 1].split(',').map(f => f.trim());
      i++;
    }
  }

  // Apply filters (AND logic)
  let results = readEntries();

  for (const tag of filters.tags) {
    results = results.filter(e => e.tags && e.tags.includes(tag));
  }
  for (const date of filters.dates) {
    if (/^\d{4}-\d{2}-\d{2}$/.test(date)) {
      results = results.filter(e => e.date === date);
    } else if (/^\d{4}-\d{2}$/.test(date)) {
      results = results.filter(e => e.date && e.date.startsWith(date));
    }
  }
  for (const file of filters.files) {
    results = results.filter(e =>
      e.files_affected && e.files_affected.some(f => f.includes(file)));
  }
  for (const text of filters.texts) {
    results = results.filter(e => {
      for (const value of Object.values(e)) {
        if (typeof value === 'string' && value.toLowerCase().includes(text)) return true;
        if (Array.isArray(value)) {
          for (const item of value) {
            if (typeof item === 'string' && item.toLowerCase().includes(text)) return true;
            if (typeof item === 'object' && item !== null) {
              for (const v of Object.values(item)) {
                if (typeof v === 'string' && v.toLowerCase().includes(text)) return true;
              }
            }
          }
        }
      }
      return false;
    });
  }

  if (results.length === 0) {
    process.stdout.write('No matching entries.\n');
    return;
  }

  // Display
  const show = (name) => !fields || fields.includes(name);

  for (const e of results) {
    process.stdout.write(`#${e.id} [${e.date}] ${e.decision}\n`);
    if (show('tags')) process.stdout.write(`  Tags: ${(e.tags || []).join(', ')}\n`);
    if (show('intent')) process.stdout.write(`  Intent: ${e.intent}\n`);
    if (show('context') && e.context) process.stdout.write(`  Context: ${e.context}\n`);
    if (show('commits') && e.commits && e.commits.length > 0) {
      process.stdout.write(`  Commits: ${e.commits.join(', ')}\n`);
    }
    if (show('files_affected') && e.files_affected) {
      process.stdout.write(`  Files: ${e.files_affected.join(', ')}\n`);
    }
    if (show('alternatives_rejected') && e.alternatives_rejected && e.alternatives_rejected.length > 0) {
      process.stdout.write(`  Alternatives rejected:\n`);
      for (const alt of e.alternatives_rejected) {
        process.stdout.write(`    - ${alt.option}: ${alt.reason}\n`);
      }
    }
    if (show('constraints') && e.constraints) {
      process.stdout.write(`  Constraints: ${e.constraints}\n`);
    }
    if (show('consequence') && e.consequence) {
      process.stdout.write(`  Consequence: ${e.consequence}\n`);
    }
    process.stdout.write('\n');
  }

  process.stdout.write(`${results.length} entries matched.\n`);
}

function addEntry(args) {
  const { aliasMap, canonicalTags } = loadMergedAliases();
  const config = loadConfig();

  let decision = null, intent = null, context = null;
  let tagsRaw = null, filesRaw = null;
  let date = new Date().toISOString().slice(0, 10);
  let commitsRaw = null, constraints = null, consequence = null;
  let type = 'decision', supersedesRaw = null;
  const alternatives = [];

  for (let i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--decision': decision = args[++i]; break;
      case '--intent': intent = args[++i]; break;
      case '--context': context = args[++i]; break;
      case '--tags': tagsRaw = args[++i]; break;
      case '--files': filesRaw = args[++i]; break;
      case '--date': date = args[++i]; break;
      case '--commits': commitsRaw = args[++i]; break;
      case '--constraints': constraints = args[++i]; break;
      case '--consequence': consequence = args[++i]; break;
      case '--alternative': alternatives.push(args[++i]); break;
      case '--type': type = args[++i]; break;
      case '--supersedes': supersedesRaw = args[++i]; break;
    }
  }

  // Flag-to-field mapping for config-driven requirement checking
  const flagFieldMap = {
    decision, intent, context,
    tags: tagsRaw, files_affected: filesRaw,
    commits: commitsRaw, constraints, consequence,
  };

  if (config && config.entryTypes && config.entryTypes[type]) {
    const typeDef = config.entryTypes[type];
    const missing = [];
    const warnings = [];

    for (const [field, fieldDef] of Object.entries(typeDef.fields)) {
      const value = flagFieldMap[field];
      const flagName = field === 'files_affected' ? '--files' : field === 'tags' ? '--tags' : `--${field}`;

      if (fieldDef.requirement === 'required' && !value) {
        missing.push(flagName);
      } else if (fieldDef.requirement === 'encouraged' && !value) {
        warnings.push(flagName);
      }
    }

    if (missing.length > 0) {
      process.stderr.write(`Error: missing required flags: ${missing.join(', ')}\n`);
      process.exit(1);
    }
    for (const w of warnings) {
      process.stderr.write(`Warning: encouraged field missing: ${w}\n`);
    }
  } else {
    // Fallback to hardcoded required list
    const missing = [];
    if (!decision) missing.push('--decision');
    if (!intent) missing.push('--intent');
    if (!context) missing.push('--context');
    if (!tagsRaw) missing.push('--tags');
    if (!filesRaw) missing.push('--files');

    if (missing.length > 0) {
      process.stderr.write(`Error: missing required flags: ${missing.join(', ')}\n`);
      process.exit(1);
    }
  }

  // Tag alias rejection
  const rawTagList = tagsRaw.split(',').map(t => t.trim()).filter(Boolean);
  if (config && config.tagAliasPolicy === 'reject') {
    for (const t of rawTagList) {
      const resolved = resolveTag(t, aliasMap);
      if (resolved !== t && resolved !== t.toLowerCase()) {
        process.stderr.write(`Error: tag "${t}" is an alias for "${resolved}". Use the canonical form.\n`);
        process.exit(1);
      }
    }
  }

  // Resolve tags via merged aliases
  const tags = rawTagList.map(t => {
    const resolved = resolveTag(t, aliasMap);
    if (!canonicalTags.includes(resolved)) {
      process.stderr.write(`Warning: unknown tag "${t}" (not in aliases)\n`);
    }
    return resolved;
  });

  // Alternative validation
  if (alternatives.length > 0) {
    for (const a of alternatives) {
      const [option, ...reasonParts] = a.split('|');
      const reason = reasonParts.join('|').trim();
      if (!reason) {
        process.stderr.write(`Error: --alternative requires format "option|reason". Reason is missing.\n`);
        process.exit(1);
      }
    }
  }

  const files = filesRaw ? filesRaw.split(',').map(f => f.trim()).filter(Boolean) : [];

  const entries = readEntries();
  const id = entries.reduce((max, e) => Math.max(max, e.id || 0), 0) + 1;

  const entry = {
    id,
    date,
    tags: [...new Set(tags)].sort(),
    decision,
  };

  if (type !== 'decision') entry.type = type;
  if (intent) entry.intent = intent;
  if (context) entry.context = context;
  if (files.length > 0) entry.files_affected = files;

  if (commitsRaw) {
    entry.commits = commitsRaw.split(',').map(c => c.trim()).filter(Boolean);
  }
  if (supersedesRaw) {
    entry.supersedes = supersedesRaw.split(',').map(s => parseInt(s.trim(), 10)).filter(n => !isNaN(n));
  }
  if (alternatives.length > 0) {
    entry.alternatives_rejected = alternatives.map(a => {
      const [option, ...reasonParts] = a.split('|');
      return { option: option.trim(), reason: reasonParts.join('|').trim() };
    });
  }
  if (constraints) entry.constraints = constraints;
  if (consequence) entry.consequence = consequence;

  // Validate against schema
  const schema = loadSchema();
  const errors = validateEntry(entry, schema);
  if (errors.length > 0) {
    process.stderr.write(`Error: validation failed:\n`);
    for (const err of errors) process.stderr.write(`  ${err}\n`);
    process.exit(1);
  }

  appendEntryAtomic(entry);
  process.stdout.write(`Added entry #${entry.id}:\n`);
  process.stdout.write(JSON.stringify(entry, null, 2) + '\n');
}

function validate() {
  if (!existsSync(DECISIONS_PATH)) {
    process.stdout.write('No decisions.jsonl found.\n');
    return;
  }

  const schema = loadSchema();
  const config = loadConfig();
  const content = readFileSync(DECISIONS_PATH, 'utf-8').trim();
  if (!content) {
    process.stdout.write('0 entries: 0 valid, 0 invalid.\n');
    return;
  }

  const lines = content.split('\n');
  let valid = 0;
  let invalid = 0;

  for (let i = 0; i < lines.length; i++) {
    if (!lines[i].trim()) continue;
    const lineNum = i + 1;
    let entry;
    try {
      entry = JSON.parse(lines[i]);
    } catch (err) {
      process.stdout.write(`Line ${lineNum}: invalid JSON — ${err.message}\n`);
      invalid++;
      continue;
    }

    const errors = validateEntry(entry, schema);

    // Config-driven per-type requirement checking
    if (config && config.entryTypes) {
      const entryType = entry.type || 'decision';
      const typeDef = config.entryTypes[entryType];
      if (typeDef) {
        for (const [field, fieldDef] of Object.entries(typeDef.fields)) {
          if (fieldDef.requirement === 'required' && !(field in entry)) {
            errors.push(`missing required field for type "${entryType}": ${field}`);
          }
        }
      }
    } else {
      // Fallback: hardcoded required list (original behaviour)
      const hardcodedRequired = ['intent', 'context', 'files_affected'];
      for (const field of hardcodedRequired) {
        if (!(field in entry) && !errors.some(e => e.includes(field))) {
          errors.push(`missing required field: ${field}`);
        }
      }
    }

    if (errors.length > 0) {
      const idStr = entry.id !== undefined ? ` (entry #${entry.id})` : '';
      process.stdout.write(`Line ${lineNum}${idStr}:\n`);
      for (const err of errors) process.stdout.write(`  ${err}\n`);
      invalid++;
    } else {
      valid++;
    }
  }

  // Check chronological order
  let orderWarnings = 0;
  let prevDate = '';
  for (let i = 0; i < lines.length; i++) {
    if (!lines[i].trim()) continue;
    let entry;
    try { entry = JSON.parse(lines[i]); } catch { continue; }
    if (entry.date && prevDate && entry.date < prevDate) {
      process.stdout.write(`Line ${i + 1} (entry #${entry.id}): date ${entry.date} precedes previous entry date ${prevDate} — out of chronological order\n`);
      orderWarnings++;
    }
    if (entry.date) prevDate = entry.date;
  }

  const total = valid + invalid;
  process.stdout.write(`${total} entries: ${valid} valid, ${invalid} invalid.`);
  if (orderWarnings > 0) process.stdout.write(` ${orderWarnings} out of order.`);
  process.stdout.write('\n');
}

// ─── CLI ───────────────────────────────────────────────────────────────────

function main() {
  const args = process.argv.slice(2);

  if (args.includes('--help') || args.includes('-h')) {
    printHelp();
    process.exit(0);
  }

  if (args.includes('--validate')) {
    validate();
    process.exit(0);
  }

  if (args.includes('--search')) {
    search(args);
    process.exit(0);
  }

  if (args.includes('--add')) {
    addEntry(args);
    process.exit(0);
  }

  printHelp();
  process.exit(0);
}

main();
