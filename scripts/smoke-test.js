#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'Sources/MarkdownStudioApp.swift'), 'utf8');
const info = fs.readFileSync(path.join(root, 'Info.plist'), 'utf8');
const { marked } = require(path.join(root, 'Sources/Resources/marked.min.js'));
const katex = require(path.join(root, 'Sources/Resources/katex.min.js'));

function expect(condition, message) {
  if (!condition) throw new Error(message);
}

const rendered = marked.parse('| A | B |\n| --- | --- |\n| **bold** | ~~old~~ |\n\n- [x] done', { gfm: true });
expect(rendered.includes('<table>'), 'GFM table did not render');
expect(rendered.includes('<del>old</del>'), 'GFM strikethrough did not render');
expect(rendered.includes('type="checkbox"'), 'GFM task list did not render');
expect(katex.renderToString('\\frac{a}{b}').includes('katex'), 'KaTeX did not render');

for (const requirement of [
  'keyboardShortcut("p", modifiers: .command)',
  'content.contentEditable = \'true\'',
  'markdownChanged',
  'confirmDiscardChanges',
  'applicationShouldTerminate',
  'katex.renderToString'
]) expect(source.includes(requirement), `Missing source requirement: ${requirement}`);

for (const requirement of ['CFBundleIconFile', 'AppIcon', 'CFBundleDocumentTypes']) {
  expect(info.includes(requirement), `Missing app metadata: ${requirement}`);
}

console.log('Smoke tests passed: GFM, KaTeX, rendered editing, safeguards, shortcuts, metadata.');
