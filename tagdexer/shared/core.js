// shared/core.js — parsing and alias resolution shared by indexer and extension
// @tagdex: tool, core, active

import { readFileSync } from 'node:fs';

/** Header marker regex — matches @tagdex: in any comment style */
export const HEADER_MARKER_RE = /@tagdex:\s*(.+)/;

/** Max lines to scan for header marker */
export const HEADER_SCAN_LINES = 20;

/** Allowlisted extensions for header scanning (JSON excluded — no comment syntax) */
export const HEADER_EXTENSIONS = new Set([
  '.py', '.js', '.ts', '.tsx', '.jsx', '.md', '.sh',
  '.yaml', '.yml', '.toml', '.html', '.css',
]);

/**
 * Load aliases.json and build lookup structures.
 * @param {string} aliasesPath - absolute path to aliases.json
 * @returns {{ aliasMap: Record<string,string>, descriptions: Record<string,string>, canonicalTags: string[] }}
 */
export function loadAliases(aliasesPath) {
  let raw;
  try {
    raw = readFileSync(aliasesPath, 'utf-8');
  } catch (err) {
    if (err.code === 'ENOENT') return { aliasMap: {}, descriptions: {}, canonicalTags: [] };
    throw err;
  }

  const data = JSON.parse(raw);
  const aliasMap = {};
  const descriptions = {};
  const canonicalTags = [];

  for (const [canonical, entry] of Object.entries(data)) {
    canonicalTags.push(canonical);
    aliasMap[canonical.toLowerCase()] = canonical;
    descriptions[canonical] = entry.description || '';
    for (const alias of entry.aliases || []) {
      aliasMap[alias.toLowerCase()] = canonical;
    }
  }

  canonicalTags.sort();
  return { aliasMap, descriptions, canonicalTags };
}

/**
 * Resolve a single raw tag to its canonical form.
 * Unknown tags pass through lowercased and trimmed.
 */
export function resolveTag(raw, aliasMap) {
  const normalized = raw.trim().toLowerCase();
  return aliasMap[normalized] || normalized;
}

/**
 * Parse a comma-separated tag string into a sorted, deduplicated array of canonical tags.
 */
export function parseTags(tagString, aliasMap) {
  if (!tagString) return [];
  return [...new Set(
    tagString
      .split(',')
      .map(t => t.trim())
      .filter(t => t.length > 0)
      .map(t => resolveTag(t, aliasMap)),
  )].sort();
}

/**
 * Scan file content for a @tagdex: header within the first HEADER_SCAN_LINES lines.
 * The marker must appear at an actual comment position, not inside backtick-quoted text.
 * Strips trailing comment closers (--> and star-slash).
 * @returns {string[]} canonical tags, or empty array if no header found
 */
export function parseHeader(content, aliasMap) {
  const lines = content.split('\n').slice(0, HEADER_SCAN_LINES);
  for (const line of lines) {
    const match = line.match(HEADER_MARKER_RE);
    if (match) {
      // Skip if the @tagdex: appears inside backtick-quoted text (e.g. markdown inline code)
      const idx = line.indexOf('@tagdex:');
      const before = line.slice(0, idx);
      const backticksBefore = (before.match(/`/g) || []).length;
      if (backticksBefore % 2 !== 0) continue; // inside backticks — not a real header

      let tagStr = match[1];
      tagStr = tagStr.replace(/\s*-->$/, '').replace(/\s*\*\/$/, '').trim();
      return parseTags(tagStr, aliasMap);
    }
  }
  return [];
}

/**
 * Parse a .tags companion file into entries.
 * Format: one entry per line, `name: tag1, tag2` for files, `name/: tag1, tag2` for folders.
 * Lines starting with # and blank lines are ignored.
 * @returns {{ name: string, tags: string[], isFolder: boolean }[]}
 */
export function parseTagsFile(content, aliasMap) {
  const entries = [];
  for (const line of content.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;

    const colonIdx = trimmed.indexOf(':');
    if (colonIdx === -1) continue;

    const rawName = trimmed.slice(0, colonIdx).trim();
    const tagStr = trimmed.slice(colonIdx + 1).trim();
    if (!rawName || !tagStr) continue;

    const isFolder = rawName.endsWith('/');
    const name = isFolder ? rawName.slice(0, -1) : rawName;

    entries.push({
      name,
      tags: parseTags(tagStr, aliasMap),
      isFolder,
    });
  }
  return entries;
}
