/* Production renderer: math is tokenized before Markdown emphasis; rich edits
 * preserve the exact source of untouched blocks instead of rewriting a file. */
const content = document.getElementById('content');
const mathTokens = new Map();
const mathPrefix = `math-${Math.random().toString(36).slice(2)}-`;
function mathHTML(token) {
  const key = mathPrefix + mathTokens.size;
  mathTokens.set(key, token);
  return `<${token.display ? 'div' : 'span'} data-math-token="${key}"></${token.display ? 'div' : 'span'}>`;
}
marked.use({gfm: true, breaks: false, extensions: [
  {
    name: 'displayMath', level: 'block', start: value => value.indexOf('$$'),
    tokenizer(value) {
      const match = /^\$\$[ \t]*\n([\s\S]+?)\n\$\$[ \t]*(?:\n|$)/.exec(value);
      if (match) return {type: 'displayMath', raw: match[0], text: match[1].trim(), display: true};
    }, renderer: mathHTML
  },
  {
    name: 'inlineMath', level: 'inline', start: value => value.indexOf('$'),
    tokenizer(value) {
      const display = /^\$\$((?:\\.|[^$\\])+?)\$\$/.exec(value);
      if (display) return {type: 'inlineMath', raw: display[0], text: display[1].trim(), display: true};
      const match = /^\$((?:\\.|[^$\\\n])+?)\$(?!\$)/.exec(value);
      if (match) return {type: 'inlineMath', raw: match[0], text: match[1].trim(), display: false};
    }, renderer: mathHTML
  }
]});

function sanitizeHTML(html) {
  const safe = new DOMParser().parseFromString(html, 'text/html');
  safe.querySelectorAll('script,style,iframe,frame,frameset,object,embed,form,button,textarea,select,option,link,meta,base,svg,math,video,audio,source,track').forEach(node => node.remove());
  safe.querySelectorAll('input').forEach(node => {
    if (node.getAttribute('type') !== 'checkbox') node.remove();
    else {
      [...node.attributes].forEach(attr => { if (!['type','checked','disabled'].includes(attr.name.toLowerCase())) node.removeAttribute(attr.name); });
      node.disabled = true;
    }
  });
  safe.querySelectorAll('*').forEach(node => {
    [...node.attributes].forEach(attr => {
      const name = attr.name.toLowerCase();
      // Browsers ignore ASCII controls inside schemes (java<TAB>script:).
      const value = attr.value.replace(/[\u0000-\u0020\u007f]/g, '').toLowerCase();
      if (name.startsWith('on') || ['style','srcdoc','srcset','formaction','action','ping','contenteditable','autofocus','download'].includes(name)) node.removeAttribute(attr.name);
      if (['href','src','xlink:href'].includes(name)) {
        const scheme = /^([a-z][a-z0-9+.-]*):/.exec(value)?.[1];
        const allowed = name === 'href' ? ['http','https','mailto','file'] : ['http','https','file'];
        const imageData = name === 'src' && /^data:image\/(png|jpeg|gif|webp);base64,/.test(value);
        if ((scheme && !allowed.includes(scheme) && !imageData) || name === 'xlink:href') node.removeAttribute(attr.name);
      }
    });
  });
  return safe.body;
}

const entries = new Map();
const originalEntries = [];
let sourceSuffix = '';
const newline = source.includes('\r\n') ? '\r\n' : '\n';
const normalizedSource = source.replace(/\r\n?/g, '\n');
const tokens = marked.lexer(normalizedSource);
if (!renderEditing) content.append(...sanitizeHTML(marked.parser(tokens)).childNodes);
else {
  let cursor = 0, originalCursor = 0, pending = '';
  function originalThrough(end) {
    const start = originalCursor;
    while (cursor < end) {
      if (source[originalCursor] === '\r' && source[originalCursor + 1] === '\n') originalCursor++;
      originalCursor++; cursor++;
    }
    return source.slice(start, originalCursor);
  }
  for (const token of tokens) {
    const position = normalizedSource.indexOf(token.raw, cursor);
    if (position < cursor) throw new Error('Cannot map Markdown token to source');
    pending += originalThrough(position);
    const raw = originalThrough(position + token.raw.length);
    if (token.type === 'space') { pending += raw; continue; }
    const blockTokens = [token]; blockTokens.links = tokens.links;
    const block = document.createElement('div');
    block.className = 'markdown-source-block';
    block.append(...sanitizeHTML(marked.parser(blockTokens)).childNodes);
    // HTML containers are supported in preview, but editing their DOM would lose
    // attributes/structure. Keep those blocks read-only; source mode can edit them.
    if (token.type === 'html') { block.contentEditable = 'false'; block.title = 'HTML 块请在左侧源码中编辑'; }
    const entry = {node: block, raw, prefix: pending};
    entries.set(block, entry); originalEntries.push(entry); pending = '';
    content.append(block);
  }
  sourceSuffix = pending + source.slice(originalCursor);
}

content.querySelectorAll('[data-math-token]').forEach(node => {
  const token = mathTokens.get(node.dataset.mathToken);
  if (!token) { node.removeAttribute('data-math-token'); return; }
  node.removeAttribute('data-math-token');
  node.dataset.markdownMath = token.text;
  node.dataset.displayMath = String(token.display);
  node.innerHTML = katex.renderToString(token.text, {throwOnError: false, displayMode: token.display, trust: false});
  if (renderEditing) node.contentEditable = 'false';
});

function escapeText(value) { return value.replace(/[\\`*_\[\]<>#!|~+$\-]/g, '\\$&').replace(/^(\s*\d+)([.)])(?=\s)/gm, '$1\\$2'); }
function inlineMarkdown(node) {
  if (node.nodeType === Node.TEXT_NODE) return escapeText(node.nodeValue);
  if (node.nodeType !== Node.ELEMENT_NODE) return '';
  if (node.dataset.markdownMath !== undefined) return node.dataset.displayMath === 'true' ? `$$\n${node.dataset.markdownMath}\n$$` : `$${node.dataset.markdownMath}$`;
  const value = Array.from(node.childNodes).map(inlineMarkdown).join('');
  switch (node.tagName) {
    case 'STRONG': case 'B': return `**${value}**`;
    case 'EM': case 'I': return `*${value}*`;
    case 'DEL': case 'S': return `~~${value}~~`;
    case 'CODE': {
      const text = node.textContent;
      const longest = Math.max(0, ...(text.match(/`+/g) || []).map(run => run.length));
      const fence = '`'.repeat(longest + 1);
      const pad = /^[ `]|[ `]$/.test(text) ? ' ' : '';
      return fence + pad + text + pad + fence;
    }
    case 'A': return `[${value}](<${(node.getAttribute('href') || '').replace(/>/g, '%3E')}>${node.title ? ` "${node.title.replace(/"/g, '&quot;')}"` : ''})`;
    case 'IMG': return `![${escapeText(node.alt || '')}](<${(node.getAttribute('src') || '').replace(/>/g, '%3E')}>)`;
    case 'BR': return '  \n';
    case 'INPUT': return node.checked ? '[x] ' : '[ ] ';
    case 'KBD': case 'MARK': case 'SUB': case 'SUP': return node.outerHTML;
    default: return value;
  }
}
function listMarkdown(list) {
  const start = Number(list.getAttribute('start') || 1);
  return Array.from(list.children).filter(node => node.tagName === 'LI').map((item, index) => {
    const prefix = list.tagName === 'OL' ? `${start + index}. ` : '- ';
    const body = Array.from(item.childNodes).map(node => ['UL','OL'].includes(node.tagName) ? '\n' + listMarkdown(node) : blockMarkdown(node)).join('').trim();
    return prefix + body.split('\n').map((line, index) => index ? ' '.repeat(prefix.length) + line : line).join('\n');
  }).join('\n');
}
function tableMarkdown(table) {
  const rows = Array.from(table.querySelectorAll('tr'));
  if (!rows.length) return '';
  const row = element => Array.from(element.children).map(cell => inlineMarkdown(cell).replace(/\n/g, '<br>').trim());
  const header = row(rows[0]);
  const divider = header.map((_, index) => {
    const align = rows[0].children[index]?.getAttribute('align');
    return align === 'center' ? ':---:' : align === 'right' ? '---:' : ':---';
  });
  return [header, divider, ...rows.slice(1).map(row)].map(cells => `| ${cells.join(' | ')} |`).join('\n');
}
function blockMarkdown(node) {
  if (node.nodeType === Node.TEXT_NODE) return inlineMarkdown(node);
  if (node.nodeType !== Node.ELEMENT_NODE) return '';
  if (node.dataset.markdownMath !== undefined) return inlineMarkdown(node);
  const children = () => Array.from(node.childNodes).map(blockMarkdown).filter(value => value.trim()).join('\n\n');
  if (/^H[1-6]$/.test(node.tagName)) return `${'#'.repeat(Number(node.tagName[1]))} ${inlineMarkdown(node).trim()}`;
  if (node.tagName === 'PRE') {
    const code = node.textContent.replace(/\n$/, '');
    const longest = Math.max(0, ...(code.match(/`+/g) || []).map(run => run.length));
    const fence = '`'.repeat(Math.max(3, longest + 1));
    const language = node.querySelector('code')?.className.match(/language-([^\s]+)/)?.[1] || '';
    return `${fence}${language}\n${code}\n${fence}`;
  }
  if (node.tagName === 'BLOCKQUOTE') return children().split('\n').map(line => `> ${line}`).join('\n');
  if (['UL','OL'].includes(node.tagName)) return listMarkdown(node);
  if (node.tagName === 'TABLE') return tableMarkdown(node);
  if (node.tagName === 'HR') return '---';
  if (node.tagName === 'DIV') return children();
  return inlineMarkdown(node);
}
function renderedToMarkdown(root) {
  const nodes = Array.from(root.childNodes);
  if (nodes.length === originalEntries.length && nodes.every((node, index) => node === originalEntries[index].node && node.innerHTML === originalEntries[index].html)) return source;
  const used = new Set();
  let result = nodes.map(node => {
    const entry = entries.get(node);
    if (!entry) return '\n\n' + blockMarkdown(node).replace(/\n/g, newline) + '\n\n';
    used.add(entry);
    if (node.innerHTML === entry.html) return entry.prefix + entry.raw;
    const trailing = entry.raw.match(/(?:\r?\n)*$/)[0];
    return entry.prefix + blockMarkdown(node).trim().replace(/\n/g, newline) + trailing;
  }).join('');
  // Invisible reference definitions must survive deleting their following block.
  for (const entry of originalEntries) if (!used.has(entry) && entry.prefix.trim()) result += '\n\n' + entry.prefix;
  return result + sourceSuffix;
}

if (renderEditing) {
  content.contentEditable = 'true'; content.spellcheck = true;
  content.setAttribute('aria-label', '渲染编辑区');
  content.querySelectorAll('input[type=checkbox]').forEach(node => {
    if (!node.closest('[contenteditable=false]')) node.disabled = false;
  });
  originalEntries.forEach(entry => { entry.html = entry.node.innerHTML; });
  let composing = false;
  const publish = () => {
    if (!composing) window.webkit?.messageHandlers.markdownChanged?.postMessage(renderedToMarkdown(content));
  };
  content.addEventListener('compositionstart', () => { composing = true; });
  content.addEventListener('compositionend', () => { composing = false; publish(); });
  content.addEventListener('input', publish);
  content.addEventListener('change', event => {
    if (event.target.matches('input[type=checkbox]')) { event.target.toggleAttribute('checked', event.target.checked); publish(); }
  });
  // Do not import executable event attributes/styles from rich clipboard HTML.
  content.addEventListener('paste', event => {
    event.preventDefault(); document.execCommand('insertText', false, event.clipboardData.getData('text/plain'));
  });
}
