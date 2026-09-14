/// The self-contained page a drive map is rendered into. `DriveMapExporter.render` swaps the
/// single placeholder `__DRIVE_MAP_JSON__` for the encoded `DriveMap`. No external resources:
/// the file must open offline, on any machine, without DiskGallery.
enum DriveMapTemplate {
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="generator" content="DiskGallery">
<title>Drive map</title>
<style>
:root {
  color-scheme: light dark;
  --paper: #F5F7F6; --ink: #16222D; --muted: #5B6A74; --rule: #D5DDDB;
  --hover: #E8EEEC; --track: #DDE5E3; --mark: #F3DE8A;
  --photos: #3D8B5C; --video: #2E6DAE; --raw: #B7821B; --audio: #7859A4;
  --documents: #5C7282; --other: #A7B1B6; --folder: #2E6DAE;
}
@media (prefers-color-scheme: dark) {
  :root {
    --paper: #0F1922; --ink: #E2E9EC; --muted: #8D9DA7; --rule: #243340;
    --hover: #172633; --track: #22323F; --mark: #6B5A1E;
    --photos: #5BB27F; --video: #5B9AD9; --raw: #D6A23F; --audio: #A186CC;
    --documents: #8CA1AF; --other: #5D6D77; --folder: #5B9AD9;
  }
}
* { box-sizing: border-box; }
[hidden] { display: none !important; }
body {
  margin: 0; background: var(--paper); color: var(--ink);
  font: 15px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  font-variant-numeric: tabular-nums; -webkit-font-smoothing: antialiased;
}
main { max-width: 1080px; margin: 0 auto; padding: 48px 20px 64px; }
h1 {
  margin: 0 0 18px; font-size: clamp(34px, 7vw, 60px); line-height: 1;
  letter-spacing: -0.03em; font-weight: 700; overflow-wrap: anywhere;
}
.facts { display: flex; flex-wrap: wrap; gap: 10px 32px; margin: 0 0 32px; }
.facts dt { font-size: 12px; color: var(--muted); }
.facts dd { margin: 0; font-weight: 600; }
.scale-bar {
  display: flex; height: 28px; border-radius: 6px; overflow: hidden;
  background-color: var(--paper);
  background-image: repeating-linear-gradient(135deg, var(--track) 0 2px, transparent 2px 7px);
  box-shadow: inset 0 0 0 1px var(--rule);
}
.scale-bar span { flex: none; height: 100%; box-shadow: inset -1px 0 0 var(--paper); }
.scale-caption {
  display: flex; flex-wrap: wrap; justify-content: space-between; gap: 4px 16px;
  margin-top: 8px; font-size: 13px; color: var(--muted);
}
.scale-caption strong { color: var(--ink); font-weight: 600; }
.legend {
  display: grid; grid-template-columns: repeat(auto-fill, minmax(160px, 1fr)); gap: 12px 24px;
  margin: 24px 0 40px; padding: 0; list-style: none;
}
.legend li { display: grid; grid-template-columns: 10px minmax(0, 1fr); column-gap: 8px; }
.swatch { width: 10px; height: 10px; border-radius: 2px; margin-top: 5px; }
.cat-name { font-weight: 600; }
.cat-detail { grid-column: 2; font-size: 13px; color: var(--muted); }
.toolbar {
  position: sticky; top: 0; z-index: 2; display: flex; flex-wrap: wrap; align-items: center; gap: 8px;
  padding: 10px 0; background: var(--paper); border-bottom: 1px solid var(--rule);
}
.toolbar input, .toolbar select, .toolbar button {
  font: inherit; font-size: 13px; color: inherit; background: transparent;
  border: 1px solid var(--rule); border-radius: 6px; padding: 6px 10px;
}
.toolbar input { flex: 1 1 220px; min-width: 0; font-size: 14px; }
.toolbar select, .toolbar button { cursor: pointer; }
.toolbar select:hover, .toolbar button:hover { background: var(--hover); }
:focus-visible { outline: 2px solid var(--folder); outline-offset: 1px; }
.status { margin: 0; padding: 10px 10px 0; font-size: 13px; color: var(--muted); }
.status:empty { display: none; }
.row {
  display: grid; grid-template-columns: minmax(0, 1fr) 96px 80px 84px 108px;
  align-items: center; column-gap: 14px; min-height: 30px;
  padding: 3px 10px 3px calc(6px + var(--d, 0) * 20px); border-radius: 5px;
}
.row:hover { background: var(--hover); }
.row.folder { cursor: pointer; }
.row.head { min-height: 0; padding-top: 10px; padding-bottom: 6px; font-size: 12px; color: var(--muted); }
.row.head:hover { background: none; }
.row.more { font-size: 13px; color: var(--muted); }
.row.more:hover { background: none; }
.more-label { grid-column: 1 / -1; padding-left: 48px; }
.cell-name { display: flex; align-items: center; gap: 7px; min-width: 0; }
.label { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.row.folder .label { font-weight: 500; }
.toggle, .toggle-space { flex: none; width: 18px; height: 18px; }
.toggle {
  display: grid; place-items: center; padding: 0; border: 0; border-radius: 4px;
  background: none; color: var(--muted); cursor: pointer;
}
.toggle:disabled { visibility: hidden; }
.chev { width: 10px; height: 10px; transition: transform 120ms ease-out; }
.toggle[aria-expanded="true"] .chev { transform: rotate(90deg); }
.glyph { flex: none; width: 16px; height: 14px; fill: var(--folder); }
.file-glyph { flex: none; width: 10px; height: 12px; margin: 0 3px; border-radius: 2px; }
.bar { display: block; height: 5px; border-radius: 3px; background: var(--track); overflow: hidden; }
.bar i { display: block; height: 100%; border-radius: 3px; }
.num { text-align: right; white-space: nowrap; }
.muted { color: var(--muted); }
.c-files, .c-date { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
mark { background: var(--mark); color: inherit; border-radius: 2px; }
footer { margin-top: 48px; padding-top: 16px; border-top: 1px solid var(--rule); font-size: 13px; color: var(--muted); }
@media (max-width: 640px) {
  main { padding-top: 28px; }
  .row { grid-template-columns: minmax(0, 1fr) 76px; padding-left: calc(2px + var(--d, 0) * 14px); }
  .c-bar, .c-files, .c-date { display: none; }
}
@media (prefers-reduced-motion: reduce) { .chev { transition: none; } }
</style>
</head>
<body>
<main>
  <header>
    <h1 id="drive-name"></h1>
    <dl class="facts" id="facts"></dl>
    <div class="scale-bar" id="scale-bar" role="img"></div>
    <div class="scale-caption" id="scale-caption"></div>
    <ul class="legend" id="legend"></ul>
  </header>
  <section aria-label="Folders and files">
    <div class="toolbar">
      <input type="search" id="search" placeholder="Search folders and files" aria-label="Search folders and files" autocomplete="off">
      <select id="sort" aria-label="Sort by">
        <option value="size">Size</option>
        <option value="name">Name</option>
        <option value="date">Date modified</option>
        <option value="kind">Kind</option>
      </select>
      <select id="order" aria-label="Sort order"></select>
      <button type="button" id="expand">Expand all</button>
      <button type="button" id="collapse">Collapse all</button>
    </div>
    <p class="status" id="status" role="status"></p>
    <div class="row head" aria-hidden="true">
      <span>Name</span><span class="c-bar"></span><span class="num">Size</span><span class="num c-files">Files</span><span class="c-date">Modified</span>
    </div>
    <div id="tree"></div>
  </section>
  <noscript><p>This map needs JavaScript to show its folders.</p></noscript>
  <footer id="footer"></footer>
</main>
<script id="map" type="application/json">__DRIVE_MAP_JSON__</script>
<script>
(() => {
  'use strict';
  const map = JSON.parse(document.getElementById('map').textContent);
  const drive = map.drive;
  const $ = (id) => document.getElementById(id);
  const el = (tag, cls, text) => {
    const node = document.createElement(tag);
    if (cls) node.className = cls;
    if (text != null) node.textContent = text;
    return node;
  };

  // Formatting
  const nf = new Intl.NumberFormat();
  const df = new Intl.DateTimeFormat(undefined, { dateStyle: 'medium' });
  const UNITS = ['KB', 'MB', 'GB', 'TB', 'PB'];
  const size = (b) => {
    if (b < 1000) return nf.format(b) + (b === 1 ? ' byte' : ' bytes');
    let v = b, i = -1;
    while (v >= 1000 && i < UNITS.length - 1) { v /= 1000; i++; }
    return (v >= 100 ? Math.round(v) : v.toFixed(1)) + ' ' + UNITS[i];
  };
  const when = (iso) => (iso ? df.format(new Date(iso)) : '');
  const files = (n) => nf.format(n) + (n === 1 ? ' file' : ' files');
  const COLORS = {
    Photos: 'var(--photos)', Video: 'var(--video)', RAW: 'var(--raw)',
    Audio: 'var(--audio)', Documents: 'var(--documents)', Other: 'var(--other)',
  };
  const extOf = (f) => {
    const dot = f.name.lastIndexOf('.');
    return (f.ext || (dot > 0 ? f.name.slice(dot + 1) : '')).toLowerCase();
  };
  const colorOf = (f) => COLORS[map.extensionCategories[extOf(f)]] || COLORS.Other;

  // Header
  const FORMATS = { apfs: 'APFS', exfat: 'exFAT', msdos: 'FAT32', hfs: 'Mac OS Extended', ntfs: 'NTFS' };
  const CONNECTIONS = { usb: 'USB', thunderbolt: 'Thunderbolt', sata: 'SATA', pcie: 'PCIe', sd: 'SD card', virtual: 'Disk image' };
  document.title = 'Map of ' + drive.name;
  $('drive-name').textContent = drive.name;
  const facts = [
    ['Files', nf.format(drive.fileCount)],
    ['Folders', nf.format(drive.folderCount)],
    ['Format', drive.fsType && (FORMATS[drive.fsType.toLowerCase()] || drive.fsType)],
    ['Connection', drive.connection && (CONNECTIONS[drive.connection] || drive.connection)],
    ['Device', drive.model],
    ['Scanned', when(drive.scannedAt)],
  ];
  for (const [label, value] of facts) {
    if (!value) continue;
    const item = el('div');
    item.append(el('dt', null, label), el('dd', null, value));
    $('facts').append(item);
  }

  // Capacity bar: one segment per category, then data outside the map, then hatched free space.
  const inFiles = map.categories.reduce((sum, c) => sum + c.bytes, 0);
  const capacity = Math.max(drive.totalCapacity || 0, inFiles);
  const segments = map.categories.map((c) => [c.name + ': ' + size(c.bytes), c.bytes, COLORS[c.name] || COLORS.Other]);
  if (drive.totalCapacity && drive.freeCapacity != null) {
    const outside = drive.totalCapacity - drive.freeCapacity - inFiles;
    if (outside > 0) segments.push(['Not in this map: ' + size(outside), outside, 'var(--track)']);
  }
  for (const [title, bytes, color] of segments) {
    if (!capacity) break;
    const seg = el('span');
    seg.style.width = (bytes / capacity) * 100 + '%';
    seg.style.background = color;
    seg.title = title;
    $('scale-bar').append(seg);
  }
  const used = el('span');
  used.append(el('strong', null, size(inFiles)), ' in files');
  $('scale-caption').append(used);
  if (drive.totalCapacity) {
    const free = el('span');
    if (drive.freeCapacity != null) free.append(el('strong', null, size(drive.freeCapacity)), ' free of ' + size(drive.totalCapacity));
    else free.append(size(drive.totalCapacity) + ' capacity');
    $('scale-caption').append(free);
  }
  $('scale-bar').setAttribute('aria-label', $('scale-caption').textContent);
  for (const c of map.categories) {
    const li = el('li');
    const swatch = el('span', 'swatch');
    swatch.style.background = COLORS[c.name] || COLORS.Other;
    li.append(swatch, el('span', 'cat-name', c.name), el('span', 'cat-detail', size(c.bytes) + ', ' + files(c.count)));
    $('legend').append(li);
  }
  $('legend').hidden = map.categories.length === 0;
  $('footer').textContent = 'Made with DiskGallery' + (map.appVersion ? ' ' + map.appVersion : '') +
    '. Exported ' + when(map.generatedAt) + '.';

  // Sorting
  const byName = (a, b) => a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: 'base' });
  const time = (x) => (x.modifiedAt ? Date.parse(x.modifiedAt) : 0);
  const PRIMARY = {
    size: (a, b) => a.bytes - b.bytes,
    name: byName,
    date: (a, b) => time(a) - time(b),
    kind: (a, b, folders) => (folders ? byName(a, b) : extOf(a).localeCompare(extOf(b))),
  };
  const ORDERS = {   // first entry is the default direction for that key
    size: { desc: 'Largest first', asc: 'Smallest first' },
    date: { desc: 'Newest first', asc: 'Oldest first' },
    name: { asc: 'A to Z', desc: 'Z to A' },
    kind: { asc: 'A to Z', desc: 'Z to A' },
  };
  let sortKey = 'size';
  let desc = true;
  const sorted = (list, folders) => {
    const primary = PRIMARY[sortKey];
    const dir = desc ? -1 : 1;
    return list.slice().sort((a, b) => dir * primary(a, b, folders) || byName(a, b));
  };
  const fillOrder = () => {
    $('order').replaceChildren(...Object.entries(ORDERS[sortKey]).map(([value, label]) => {
      const option = el('option', null, label);
      option.value = value;
      return option;
    }));
    $('order').value = desc ? 'desc' : 'asc';
  };
  $('sort').addEventListener('change', (e) => {
    sortKey = e.target.value;
    desc = Object.keys(ORDERS[sortKey])[0] === 'desc';
    fillOrder();
    render();
  });
  $('order').addEventListener('change', (e) => { desc = e.target.value === 'desc'; render(); });

  // Open folders: level one starts expanded. Search keeps its own set so clearing it restores yours.
  const expanded = new Set(map.root.folders.map((f) => f.relPath));
  let searchOpen = new Set();
  let rawQuery = '';
  let query = '';
  let hits = 0;
  let filtered = null;
  const openSet = () => (query ? searchOpen : expanded);

  // A copy of `folder` pruned to matches, or null. A matching folder keeps all of its contents.
  const filter = (folder, isRoot) => {
    if (!isRoot && folder.name.toLowerCase().includes(query)) { hits++; return folder; }
    const folders = folder.folders.map((f) => filter(f, false)).filter(Boolean);
    const matches = folder.files.filter((f) => f.name.toLowerCase().includes(query));
    hits += matches.length;
    if (!folders.length && !matches.length) return null;
    searchOpen.add(folder.relPath);
    return Object.assign({}, folder, { folders, files: matches, moreFiles: 0 });
  };
  const applySearch = (value) => {
    rawQuery = value.trim();
    query = rawQuery.toLowerCase();
    hits = 0;
    searchOpen = new Set();
    filtered = query ? filter(map.root, true) || Object.assign({}, map.root, { folders: [], files: [], moreFiles: 0 }) : null;
    render();
  };
  let debounce;
  $('search').addEventListener('input', (e) => {
    clearTimeout(debounce);
    debounce = setTimeout(() => applySearch(e.target.value), 150);
  });

  const everyFolder = (folder, out) => {
    for (const f of folder.folders) { out.push(f.relPath); everyFolder(f, out); }
    return out;
  };
  // ponytail: expand all renders every row; fine to ~50k folders, virtualize if maps get bigger.
  $('expand').addEventListener('click', () => {
    const set = openSet();
    for (const path of everyFolder(filtered || map.root, [])) set.add(path);
    render();
  });
  $('collapse').addEventListener('click', () => { openSet().clear(); render(); });

  // Tree
  const CHEVRON = '<svg class="chev" viewBox="0 0 10 10" aria-hidden="true"><path d="M3.5 1.5 7 5 3.5 8.5" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>';
  const FOLDER = '<svg class="glyph" viewBox="0 0 16 14" aria-hidden="true"><path d="M1 2.5A1.5 1.5 0 0 1 2.5 1h3.4l1.6 1.8h6A1.5 1.5 0 0 1 15 4.3v7.2a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 1 11.5z"/></svg>';

  const labelOf = (text) => {
    const span = el('span', 'label');
    span.title = text;
    const at = query ? text.toLowerCase().indexOf(query) : -1;
    if (at < 0) { span.textContent = text; return span; }
    span.append(text.slice(0, at), el('mark', null, text.slice(at, at + query.length)), text.slice(at + query.length));
    return span;
  };
  const bar = (bytes, total, color, depth) => {
    const track = el('span', 'bar c-bar');
    const fill = el('i');
    const pct = total > 0 ? (bytes / total) * 100 : 0;
    fill.style.width = (bytes > 0 ? Math.max(pct, 1.5) : 0) + '%';
    fill.style.background = color;
    track.append(fill);
    track.title = Math.round(pct) + (depth === 0 ? '% of the drive' : '% of the folder');
    return track;
  };

  const folderNode = (f, depth, parentBytes) => {
    const node = el('div', 'node');
    const row = el('div', 'row folder');
    row.style.setProperty('--d', depth);
    const hasKids = f.folders.length > 0 || f.files.length > 0 || f.moreFiles > 0;
    const toggle = el('button', 'toggle');
    toggle.type = 'button';
    toggle.innerHTML = CHEVRON;
    toggle.disabled = !hasKids;
    const name = el('span', 'cell-name');
    name.append(toggle);
    name.insertAdjacentHTML('beforeend', FOLDER);
    name.append(labelOf(f.name));
    row.append(name, bar(f.bytes, parentBytes, 'var(--folder)', depth), el('span', 'num', size(f.bytes)),
      el('span', 'num muted c-files', files(f.fileCount)), el('span', 'muted c-date', when(f.modifiedAt)));
    const kids = el('div', 'kids');
    node.append(row, kids);
    const setOpen = (open) => {
      toggle.setAttribute('aria-expanded', String(open));
      toggle.setAttribute('aria-label', (open ? 'Collapse ' : 'Expand ') + f.name);
      kids.hidden = !open;
      if (open && !kids.firstChild) appendChildren(kids, f, depth + 1);
    };
    setOpen(hasKids && openSet().has(f.relPath));
    if (hasKids) {
      row.addEventListener('click', () => {
        const open = kids.hidden;
        if (open) openSet().add(f.relPath); else openSet().delete(f.relPath);
        setOpen(open);
      });
    }
    return node;
  };

  const fileRow = (f, depth, parentBytes) => {
    const row = el('div', 'row file');
    row.style.setProperty('--d', depth);
    const color = colorOf(f);
    const glyph = el('span', 'file-glyph');
    glyph.style.background = color;
    const name = el('span', 'cell-name');
    name.append(el('span', 'toggle-space'), glyph, labelOf(f.name));
    row.append(name, bar(f.bytes, parentBytes, color, depth), el('span', 'num', size(f.bytes)),
      el('span', 'num muted c-files', extOf(f)), el('span', 'muted c-date', when(f.modifiedAt)));
    return row;
  };

  function appendChildren(parent, folder, depth) {
    for (const f of sorted(folder.folders, true)) parent.append(folderNode(f, depth, folder.bytes));
    for (const f of sorted(folder.files, false)) parent.append(fileRow(f, depth, folder.bytes));
    if (folder.moreFiles > 0) {
      const row = el('div', 'row more');
      row.style.setProperty('--d', depth);
      row.append(el('span', 'more-label', '…and ' + nf.format(folder.moreFiles) + (folder.moreFiles === 1 ? ' more file' : ' more files')));
      parent.append(row);
    }
  }

  const statusText = () => {
    const scope = !map.includesFiles
      ? ' This map lists folders only, so search skips file names.'
      : map.filesPerFolder != null ? ' Search covers the ' + map.filesPerFolder + ' largest files in each folder.' : '';
    if (query) return (hits ? nf.format(hits) + (hits === 1 ? ' match.' : ' matches.') : 'Nothing matches “' + rawQuery + '”.') + scope;
    return map.root.folders.length || map.root.files.length ? '' : 'This drive has no files.';
  };

  function render() {
    const fragment = document.createDocumentFragment();
    appendChildren(fragment, filtered || map.root, 0);
    $('tree').replaceChildren(fragment);
    $('status').textContent = statusText();
  }

  fillOrder();
  render();
})();
</script>
</body>
</html>
"""#
}
