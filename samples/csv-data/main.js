/**
 * Data Studio (CSV) — analyze CSV data inside a ZAgents chat (sample module).
 *
 * Demonstrates: storage-only per-chat datasets, a real RFC 4180 CSV parser
 * (quoted fields, embedded commas/newlines, escaped quotes, delimiter
 * auto-detection), numeric-aware column typing, aggregations, filters and
 * an ASCII bar chart / histogram renderer sized for the chat's output cap.
 *
 * Commands (manifest `commands: ["csv"]` routes `/csv …` here):
 *   /csv load <name> \n <paste the CSV on the following lines>
 *   /csv sample                 load a built-in demo dataset
 *   /csv list                   stored datasets (rows × cols)
 *   /csv head <name> [n]        first rows as a fixed-width table
 *   /csv stats <name>           per-column type + summary statistics
 *   /csv chart <name> <col>     bar chart (text col) / histogram (numeric)
 *   /csv top <name> <col> [n]   most frequent values
 *   /csv sort <name> <col> [desc]  preview sorted by a column
 *   /csv filter <name> <col> <op> <value>   ops: = != > < >= <= contains
 *   /csv sum|avg|min|max|count <name> <col>
 *   /csv remove <name>          delete a dataset
 *   /csv help
 */
async function main() {
  const info = zagents.info;
  const raw = (info.prompt || '');
  // everything after the first line is the CSV payload (for /csv load)
  const nl = raw.indexOf('\n');
  const firstLine = (nl >= 0 ? raw.slice(0, nl) : raw).trim();
  const rest = nl >= 0 ? raw.slice(nl + 1).trim() : '';
  const argv = firstLine.replace(/^\/[A-Za-z0-9_-]+\s*/, '').trim();
  let out = [];
  const say = (...xs) => { out.push(xs.map(String).join(' ')); };

  try {
    if (!argv || argv === 'help') {
      help(say);
    } else if (argv === 'sample') {
      await loadCmd(say, 'sample', SAMPLE_CSV);
    } else if (argv === 'list') {
      await listCmd(say);
    } else if (argv.startsWith('load ')) {
      if (!rest) {
        say('Paste the CSV on the lines AFTER the command, e.g.:');
        say('  /csv sales');
        say('  name,qty,price');
        say(' Widget,3,9.99');
        say('  Gadget,1,24.5');
        return finish(say, out);
      }
      await loadCmd(say, argv.slice(5).trim(), rest);
    } else if (argv === 'removeall') {
      const names = Object.keys(await datasets());
      for (const n of names) await zagents.storage.remove('ds:' + n);
      say('🧹 Removed ' + names.length + ' dataset(s) from this chat.');
    } else {
      // <verb> <name> [rest…]
      const sp = argv.indexOf(' ');
      const verb = sp < 0 ? argv : argv.slice(0, sp);
      const argsStr = sp < 0 ? '' : argv.slice(sp + 1).trim();
      const parts = argsStr.split(/\s+/).filter(Boolean);
      const name = parts.shift() || '';
      const ds = await getDs(name);
      if (!ds) { say('❌ No dataset "' + name + '" — /csv list, or load one with /csv load.'); return finish(say, out); }
      switch (verb) {
        case 'head': headCmd(say, ds, parts[0]); break;
        case 'stats': statsCmd(say, ds); break;
        case 'chart': chartCmd(say, ds, parts[0]); break;
        case 'top': topCmd(say, ds, parts[0], parts[1]); break;
        case 'sort': sortCmd(say, ds, parts[0], parts[1]); break;
        case 'filter': filterCmd(say, ds, parts[0], parts[1], parts.slice(2).join(' ')); break;
        case 'sum': case 'avg': case 'min': case 'max': case 'count':
          aggCmd(say, ds, verb, parts[0]); break;
        case 'remove': await removeDs(name); say('🗑️ Removed "' + name + '".'); break;
        default: say('Unknown verb "' + verb + '" — /csv help.');
      }
    }
  } catch (e) {
    say('❌ ' + (e && e.message ? e.message : e));
  }
  return finish(say, out);
}

function finish(say, out) {
  return (async () => {
    for (const line of out) await zagents.log(line);
    return { module: 'csv-data' };
  })();
}

// ------------------------------------------------------------------ help

function help(say) {
  say('📊 Data Studio (CSV) — analyze tabular data in this chat. Commands:');
  say('  /csv load <name>  \\n <paste CSV on the next lines>');
  say('  /csv sample       load the built-in demo dataset');
  say('  /csv list · /csv remove <name>');
  say('  /csv head <name> [n]          preview rows');
  say('  /csv stats <name>             types + min/max/mean/median/std, uniques');
  say('  /csv chart <name> <col>       ASCII bar chart / histogram');
  say('  /csv top <name> <col> [n]     most frequent values');
  say('  /csv sort <name> <col> [desc] sorted preview');
  say('  /csv filter <name> <col> <op> <value>   ops: = != > < >= <= contains');
  say('  /csv sum|avg|min|max|count <name> <col>');
  say('');
  say('Quoted fields, embedded commas/newlines and , ; tab delimiters are');
  say('handled automatically. Datasets are scoped to THIS chat.');
}

// ------------------------------------------------------------- commands

async function loadCmd(say, name, text) {
  if (!/^[A-Za-z0-9_-]{1,24}$/.test(name)) {
    throw new Error('Dataset name must be 1-24 chars: letters, digits, - _');
  }
  const parsed = parseCsv(text);
  if (parsed.rows.length < 1) throw new Error('No data rows found.');
  if (parsed.rows[0].length < 1) throw new Error('No columns detected.');
  const ds = {
    name: name,
    header: parsed.header,
    rows: parsed.rows,
    delimiter: parsed.delimiter,
    loadedAt: new Date().toISOString(),
  };
  const payload = JSON.stringify(ds);
  if (payload.length > 56000) {
    throw new Error('Dataset too large for per-chat storage (' +
      Math.round(payload.length / 1024) + ' KB > 56 KB). Trim rows/columns.');
  }
  await zagents.storage.set('ds:' + name, ds);
  const numeric = ds.header.filter(h => colType(ds, h) === 'numeric').length;
  say('✅ Loaded "' + name + '": ' + ds.rows.length + ' rows × ' + ds.header.length +
      ' columns (delimiter "' + escapeShow(ds.delimiter) + '", ' + numeric + ' numeric).');
  say('   Try: /csv stats ' + name + ' · /csv head ' + name + ' 5 · /csv chart ' + name + ' ' + ds.header[0]);
}

function listCmd(say) {
  return (async () => {
    const all = await datasets();
    const names = Object.keys(all);
    if (!names.length) {
      say('📊 No datasets in this chat. Paste one: /csv load <name> + CSV lines,');
      say('   or try the demo: /csv sample');
      return;
    }
    say('📊 Datasets in THIS chat:');
    for (const n of names.sort()) {
      const ds = all[n];
      say('   • ' + n + ' — ' + ds.rows.length + ' rows × ' + ds.header.length +
          ' cols (' + ds.header.slice(0, 4).join(', ') + (ds.header.length > 4 ? ', …' : '') + ')');
    }
  })();
}

const TABLE_ROWS = 12;
const CELL_MAX = 20;

function headCmd(say, ds, nArg) {
  const n = Math.min(Math.max(parseInt(nArg, 10) || 5, 1), 25);
  printTable(say, ds.header, ds.rows.slice(0, n), ds.rows.length);
}

function printTable(say, header, rows, totalRows) {
  const widths = header.map(h => Math.min(Math.max(h.length, 4), CELL_MAX));
  for (const r of rows) {
    r.forEach((c, i) => { widths[i] = Math.min(Math.max(widths[i], String(c).length), CELL_MAX); });
  }
  const fmtRow = (cells) => cells.map((c, i) => String(c).slice(0, CELL_MAX).padEnd(widths[i])).join(' | ');
  say('┌ ' + fmtRow(header));
  say('├' + widths.map(w => '-'.repeat(w + 2)).join('+'));
  for (const r of rows) say('│ ' + fmtRow(r));
  const more = totalRows - rows.length;
  if (more > 0) say('… +' + more + ' more row(s)');
}

function colIndex(ds, col) {
  const i = ds.header.findIndex(h => h.toLowerCase() === String(col || '').toLowerCase());
  if (i < 0) throw new Error('No column "' + col + '" — columns: ' + ds.header.join(', '));
  return i;
}

function colType(ds, header) {
  const i = ds.header.indexOf(header);
  let numeric = 0, seen = 0;
  for (const r of ds.rows.slice(0, 200)) {
    const v = (r[i] ?? '').trim();
    if (v === '') continue;
    seen++;
    if (isNumeric(v)) numeric++;
  }
  return seen > 0 && numeric / seen >= 0.8 ? 'numeric' : 'text';
}

function isNumeric(s) {
  return /^[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?$/.test(String(s).trim());
}

function num(v) {
  return parseFloat(String(v).trim());
}

function statsCmd(say, ds) {
  say('📈 "' + ds.name + '" — ' + ds.rows.length + ' rows × ' + ds.header.length + ' columns');
  for (const h of ds.header) {
    const i = ds.header.indexOf(h);
    const vals = ds.rows.map(r => (r[i] ?? '').trim());
    const nonEmpty = vals.filter(v => v !== '');
    if (colType(ds, h) === 'numeric') {
      const nums = nonEmpty.map(num).filter(x => !isNaN(x));
      nums.sort((a, b) => a - b);
      const mean = nums.reduce((s, x) => s + x, 0) / nums.length;
      const median = nums.length % 2
        ? nums[(nums.length - 1) / 2]
        : (nums[nums.length / 2 - 1] + nums[nums.length / 2]) / 2;
      const variance = nums.reduce((s, x) => s + (x - mean) ** 2, 0) / Math.max(1, nums.length - 1);
      say('   ' + h + ' [numeric] n=' + nums.length +
          ' · min ' + fmtNum(nums[0]) + ' · max ' + fmtNum(nums[nums.length - 1]) +
          ' · mean ' + fmtNum(mean) + ' · median ' + fmtNum(median) +
          ' · std ' + fmtNum(Math.sqrt(variance)) +
          (vals.length - nonEmpty.length ? ' · ' + (vals.length - nonEmpty.length) + ' missing' : ''));
    } else {
      const uniq = new Set(nonEmpty);
      const counts = new Map();
      for (const v of nonEmpty) counts.set(v, (counts.get(v) || 0) + 1);
      const top = [...counts.entries()].sort((a, b) => b[1] - a[1]).slice(0, 3);
      say('   ' + h + ' [text] n=' + nonEmpty.length + ' · ' + uniq.size + ' unique' +
        (top.length ? ' · top: ' + top.map(([v, c]) => clipCell(v) + '×' + c).join(', ') : '') +
        (vals.length - nonEmpty.length ? ' · ' + (vals.length - nonEmpty.length) + ' missing' : ''));
    }
  }
}

function chartCmd(say, ds, col) {
  const i = colIndex(ds, col);
  const h = ds.header[i];
  if (colType(ds, h) === 'numeric') {
    const nums = ds.rows.map(r => num(r[i])).filter(x => !isNaN(x));
    if (!nums.length) { say('No numeric values in "' + h + '".'); return; }
    const buckets = 8;
    const min = Math.min(...nums), max = Math.max(...nums);
    const w = Math.max((max - min) / buckets, 1e-9);
    const counts = new Array(buckets).fill(0);
    for (const x of nums) counts[Math.min(buckets - 1, Math.floor((x - min) / w))]++;
    const peak = Math.max(...counts);
    say('📊 Histogram of ' + h + ' (' + nums.length + ' values, ' + buckets + ' buckets):');
    for (let b = 0; b < buckets; b++) {
      const lo = min + b * w, hi = lo + w;
      const bar = '█'.repeat(Math.max(1, Math.round((counts[b] / peak) * 28)));
      say('  ' + fmtNum(lo).padStart(10) + ' – ' + fmtNum(hi).padEnd(10) + ' │' + bar + ' ' + counts[b]);
    }
  } else {
    const counts = new Map();
    for (const r of ds.rows) {
      const v = (r[i] ?? '').trim() || '(empty)';
      counts.set(v, (counts.get(v) || 0) + 1);
    }
    const top = [...counts.entries()].sort((a, b) => b[1] - a[1]).slice(0, 8);
    const peak = top[0] ? top[0][1] : 1;
    say('📊 Top values of ' + h + ':');
    for (const [v, c] of top) {
      const bar = '█'.repeat(Math.max(1, Math.round((c / peak) * 28)));
      say('  ' + clipCell(v).padEnd(CELL_MAX) + ' │' + bar + ' ' + c);
    }
    const rest = ds.rows.length - top.reduce((s, [, c]) => s + c, 0);
    if (rest > 0) say('  (' + rest + ' more rows in other values)');
  }
}

function topCmd(say, ds, col, nArg) {
  const i = colIndex(ds, col);
  const n = Math.min(Math.max(parseInt(nArg, 10) || 5, 1), 15);
  const counts = new Map();
  for (const r of ds.rows) {
    const v = (r[i] ?? '').trim() || '(empty)';
    counts.set(v, (counts.get(v) || 0) + 1);
  }
  const top = [...counts.entries()].sort((a, b) => b[1] - a[1]).slice(0, n);
  say('🔝 Most frequent in ' + ds.header[i] + ':');
  for (const [v, c] of top) say('   ' + clipCell(v) + ' — ' + c + '× (' + Math.round(c * 100 / ds.rows.length) + '%)');
}

function sortCmd(say, ds, col, dir) {
  const i = colIndex(ds, col);
  const desc = (dir || '').toLowerCase().startsWith('desc');
  const numeric = colType(ds, ds.header[i]) === 'numeric';
  const idx = ds.rows.map((r, ri) => ({ r: r, ri: ri }));
  idx.sort((a, b) => {
    let cmp = 0;
    if (numeric) cmp = (isNaN(num(a.r[i])) ? 1 : num(a.r[i])) - (isNaN(num(b.r[i])) ? 1 : num(b.r[i]));
    else cmp = String(a.r[i] ?? '').toLowerCase().localeCompare(String(b.r[i] ?? '').toLowerCase());
    return desc ? -cmp : cmp;
  });
  const rows = idx.slice(0, TABLE_ROWS).map(x => x.r);
  printTable(say, ds.header, rows, ds.rows.length);
  say('(sorted by ' + ds.header[i] + (desc ? ' descending' : ' ascending') + ' — preview of ' + TABLE_ROWS + ')');
}

function filterCmd(say, ds, col, op, value) {
  const i = colIndex(ds, col);
  const ops = ['=', '!=', '>', '<', '>=', '<=', 'contains'];
  if (!ops.includes(op)) throw new Error('Unknown operator "' + op + '" — use: ' + ops.join(' '));
  const numeric = colType(ds, ds.header[i]) === 'numeric' && isNumeric(value);
  const matches = ds.rows.filter(r => {
    const v = (r[i] ?? '').trim();
    if (numeric) {
      const a = num(v), b = num(value);
      switch (op) {
        case '=': return a === b;
        case '!=': return a !== b;
        case '>': return a > b;
        case '<': return a < b;
        case '>=': return a >= b;
        case '<=': return a <= b;
      }
    }
    switch (op) {
      case '=': return v.toLowerCase() === String(value).toLowerCase();
      case '!=': return v.toLowerCase() !== String(value).toLowerCase();
      case 'contains': return v.toLowerCase().includes(String(value).toLowerCase());
      default: return v.localeCompare(String(value), undefined, { numeric: true }) > 0 && op.startsWith('>') ||
        v.localeCompare(String(value), undefined, { numeric: true }) < 0 && op.startsWith('<');
    }
  });
  say('🔎 ' + ds.header[i] + ' ' + op + ' ' + value + ' → ' + matches.length + ' of ' + ds.rows.length + ' rows:');
  if (matches.length) printTable(say, ds.header, matches.slice(0, 8), matches.length);
  if (matches.length > 8) say('(showing first 8 — refine with /csv filter …)');
}

function aggCmd(say, ds, verb, col) {
  if (verb === 'count') {
    const i = colIndex(ds, col);
    const nonEmpty = ds.rows.filter(r => (r[i] ?? '').trim() !== '').length;
    say('🔢 count(' + ds.header[i] + ') = ' + nonEmpty + ' non-empty of ' + ds.rows.length);
    return;
  }
  const i = colIndex(ds, col);
  if (colType(ds, ds.header[i]) !== 'numeric') {
    throw new Error('"' + ds.header[i] + '" is not numeric — /csv stats shows column types.');
  }
  const nums = ds.rows.map(r => num(r[i])).filter(x => !isNaN(x));
  if (!nums.length) throw new Error('No numeric values in "' + ds.header[i] + '".');
  const sum = nums.reduce((s, x) => s + x, 0);
  switch (verb) {
    case 'sum': say('🔢 sum(' + ds.header[i] + ') = ' + fmtNum(sum) + '  (n=' + nums.length + ')'); break;
    case 'avg': say('🔢 avg(' + ds.header[i] + ') = ' + fmtNum(sum / nums.length)); break;
    case 'min': say('🔢 min(' + ds.header[i] + ') = ' + fmtNum(Math.min(...nums))); break;
    case 'max': say('🔢 max(' + ds.header[i] + ') = ' + fmtNum(Math.max(...nums))); break;
  }
}

// ------------------------------------------------------ CSV (RFC 4180)

function detectDelimiter(text) {
  const firstLine = text.split(/\r?\n/, 1)[0] || '';
  const counts = { ',': 0, ';': 0, '\t': 0 };
  let inQ = false;
  for (const ch of firstLine) {
    if (ch === '"') inQ = !inQ;
    else if (!inQ && ch in counts) counts[ch]++;
  }
  return Object.entries(counts).sort((a, b) => b[1] - a[1])[0][0] || ',';
}

function parseCsv(text) {
  const delim = detectDelimiter(text);
  const rows = [];
  let row = [], field = '', inQ = false;
  const src = String(text || '').replace(/\r\n/g, '\n').replace(/\r/g, '\n');
  for (let p = 0; p < src.length; p++) {
    const ch = src[p];
    if (inQ) {
      if (ch === '"') {
        if (src[p + 1] === '"') { field += '"'; p++; }
        else inQ = false;
      } else field += ch;
    } else if (ch === '"') {
      inQ = true;
    } else if (ch === delim) {
      row.push(field); field = '';
    } else if (ch === '\n') {
      row.push(field); field = '';
      if (row.length > 1 || row[0].trim() !== '') rows.push(row);
      row = [];
    } else field += ch;
  }
  row.push(field);
  if (row.length > 1 || row[0].trim() !== '') rows.push(row);
  if (!rows.length) return { header: [], rows: [], delimiter: delim };
  const header = rows[0].map((h, i) => (h.trim() || 'col' + (i + 1)));
  const data = rows.slice(1).filter(r => r.some(c => c.trim() !== ''));
  return { header: header, rows: data, delimiter: delim };
}

// ------------------------------------------------------------ storage

async function datasets() {
  const all = {};
  for (const k of await zagents.storage.keys()) {
    if (!k.startsWith('ds:')) continue;
    try { all[k.slice(3)] = await zagents.storage.get(k); } catch (_) { /* skip */ }
  }
  return all;
}

async function getDs(name) {
  if (!name) return null;
  try { return await zagents.storage.get('ds:' + name); } catch (_) { return null; }
}

async function removeDs(name) {
  await zagents.storage.remove('ds:' + name);
}

// ------------------------------------------------------------ helpers

function fmtNum(x) {
  if (typeof x !== 'number' || isNaN(x)) return String(x);
  if (Number.isInteger(x) && Math.abs(x) < 1e15) return String(x);
  const s = Math.abs(x) >= 1e6 || (Math.abs(x) < 1e-3 && x !== 0) ? x.toExponential(4) : x.toPrecision(6);
  return s.replace(/(\.\d*?)0+($|e)/, '$1$2').replace(/\.$/, '');
}

function clipCell(s) {
  const t = String(s ?? '');
  return t.length <= CELL_MAX ? t : t.slice(0, CELL_MAX - 1) + '…';
}

function escapeShow(d) {
  return d === '\t' ? '\\t' : d;
}

// built-in demo dataset
const SAMPLE_CSV = [
  'product,category,units,revenue,rating',
  'Espresso Machine,Appliances,42,3779.58,4.6',
  'Grinder,Appliances,67,2003.33,4.4',
  'Mug Set,Kitchenware,210,1468.90,4.8',
  'Pour Over Kit,Kitchenware,88,1319.12,4.7',
  'Milk Frother,Appliances,134,1071.66,3.9',
  'Scale,Kitchenware,95,709.05,4.5',
  'Tamper,Accessories,180,538.20,4.2',
  'Filter Papers,Accessories,520,462.80,4.9',
  'Cold Brew Bottle,Accessories,143,642.14,4.1',
  'Travel Press,Accessories,76,605.84,4.3',
].join('\n');

module.exports = main();
