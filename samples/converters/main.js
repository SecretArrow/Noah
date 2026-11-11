/**
 * Currency & Units — two everyday converters for ZAgents (sample module).
 *
 * Demonstrates: a manifest `allowedHosts` allowlist locking the only
 * network call to the free open.er-api.com rate endpoint (no API key),
 * per-chat rate caching with a 6-hour TTL via `zagents.storage`, and a
 * fully OFFLINE unit engine (length/mass/temperature/data/speed/volume/
 * area/time) with generous alias handling.
 *
 * Commands (manifest `commands: ["cur", "unit"]`):
 *   /cur 100 usd to idr    convert (amount optional, default 1)
 *   /cur usd idr           same, short form
 *   /cur rates <base> [n]  top-n rates table (default 12)
 *   /cur codes             the ~40 popular codes the shortcut table knows
 *   /unit 5 km to mi       length, mass, data, speed, volume, area, time
 *   /unit 72 f to c        temperature (c/f/k)
 *   /unit help · /cur help
 */
async function main() {
  const info = zagents.info;
  const raw = (info.prompt || '').trim();
  let argv = raw.replace(/^\/[A-Za-z0-9_-]+\s*/, '').trim();
  // the same module serves two commands — drop whichever keyword led here
  argv = argv.replace(/^(cur|unit)\s+/i, '').trim();
  const isUnit = /^\/unit/i.test(raw);
  let out = [];
  const say = (...xs) => { out.push(xs.map(String).join(' ')); };

  try {
    if (isUnit) {
      await unitCmd(say, argv);
    } else {
      await curCmd(say, argv);
    }
  } catch (e) {
    say('❌ ' + (e && e.message ? e.message : e));
  }

  for (const line of out) await zagents.log(line);
  return { module: 'converters', handled: argv.slice(0, 40) };
}

// ============================================================== currency

const POPULAR = [
  ['USD', 'US Dollar'], ['EUR', 'Euro'], ['IDR', 'Indonesian Rupiah'],
  ['SGD', 'Singapore Dollar'], ['MYR', 'Malaysian Ringgit'],
  ['JPY', 'Japanese Yen'], ['GBP', 'British Pound'], ['AUD', 'Australian Dollar'],
  ['CNY', 'Chinese Yuan'], ['HKD', 'Hong Kong Dollar'], ['KRW', 'South Korean Won'],
  ['INR', 'Indian Rupee'], ['PHP', 'Philippine Peso'], ['THB', 'Thai Baht'],
  ['VND', 'Vietnamese Dong'], ['TWD', 'Taiwan Dollar'], ['CHF', 'Swiss Franc'],
  ['CAD', 'Canadian Dollar'], ['NZD', 'New Zealand Dollar'], ['BRL', 'Brazilian Real'],
  ['MXN', 'Mexican Peso'], ['ZAR', 'South African Rand'], ['SAR', 'Saudi Riyal'],
  ['AED', 'UAE Dirham'], ['TRY', 'Turkish Lira'], ['RUB', 'Russian Ruble'],
  ['PLN', 'Polish Zloty'], ['SEK', 'Swedish Krona'], ['NOK', 'Norwegian Krone'],
  ['DKK', 'Danish Krone'], ['CZK', 'Czech Koruna'], ['HUF', 'Hungarian Forint'],
  ['ILS', 'Israeli Shekel'], ['EGP', 'Egyptian Pound'], ['NGN', 'Nigerian Naira'],
  ['PKR', 'Pakistani Rupee'], ['BDT', 'Bangladeshi Taka'], ['LKR', 'Sri Lankan Rupee'],
  ['ARS', 'Argentine Peso'], ['CLP', 'Chilean Peso'], ['COP', 'Colombian Peso'],
];

// friendly aliases → ISO code (subset; the API accepts any ISO code too)
const CUR_ALIAS = {
  dollar: 'USD', dollars: 'USD', bucks: 'USD', usd: 'USD',
  euro: 'EUR', euros: 'EUR', eur: 'EUR',
  rupiah: 'IDR', rp: 'IDR', idr: 'IDR',
  ringgit: 'MYR', myr: 'MYR',
  yen: 'JPY', jpy: 'JPY',
  pound: 'GBP', pounds: 'GBP', gbp: 'GBP', sterling: 'GBP',
  yuan: 'CNY', cny: 'CNY', rmb: 'CNY',
  won: 'KRW', krw: 'KRW',
  rupee: 'INR', rupees: 'INR', inr: 'INR',
  baht: 'THB', thb: 'THB', franc: 'CHF', chf: 'CHF',
  dirham: 'AED', aed: 'AED', riyal: 'SAR', sar: 'SAR',
  shekel: 'ILS', ils: 'ILS', rand: 'ZAR', zar: 'ZAR',
};

const CACHE_KEY = 'curCache';
const CACHE_TTL_MS = 6 * 3600 * 1000;

async function getRates(base) {
  base = base.toUpperCase();
  const cache = (await zagents.storage.get(CACHE_KEY)) || {};
  const hit = cache[base];
  if (hit && Date.now() - hit.at < CACHE_TTL_MS) return hit.rates;
  const resp = await zagents.http.request('https://open.er-api.com/v6/latest/' + base, { timeoutMs: 15000 });
  if (!resp.ok) throw new Error('Rate service returned HTTP ' + resp.status + ' — try again later.');
  const data = typeof resp.body === 'object' ? resp.body : JSON.parse(await resp.text());
  if (!data || data.result !== 'success' || !data.rates) {
    throw new Error('Rate service response unusable' + (data && data['error-type'] ? ': ' + data['error-type'] : ''));
  }
  cache[base] = { at: Date.now(), rates: data.rates };
  // keep the cache small (the 8 most recent bases)
  const keys = Object.keys(cache).filter(k => k !== base);
  while (keys.length > 8) delete cache[keys.shift()];
  await zagents.storage.set(CACHE_KEY, cache);
  return data.rates;
}

function resolveCode(word) {
  const w = String(word || '').toLowerCase().replace(/[^a-z]/g, '');
  if (!w) return null;
  if (CUR_ALIAS[w]) return CUR_ALIAS[w];
  const upper = w.toUpperCase();
  if (POPULAR.some(([c]) => c === upper)) return upper;
  if (/^[a-z]{3}$/.test(w)) return upper; // assume a valid ISO code
  return null;
}

async function curCmd(say, argv) {
  if (!argv || argv === 'help') {
    say('💱 Currency — live mid-market rates (open.er-api.com, cached 6h). Usage:');
    say('  /cur 100 usd to idr     convert an amount');
    say('  /cur usd idr            short form (amount 1)');
    say('  /cur rates idr 15       rate table vs a base');
    say('  /cur codes              popular codes list');
    return;
  }
  if (argv === 'codes') {
    say('💱 Popular codes (any ISO code works):');
    const rows = [];
    for (let i = 0; i < POPULAR.length; i += 4) {
      rows.push(POPULAR.slice(i, i + 4).map(([c]) => c).join('  '));
    }
    for (const r of rows) say('   ' + r);
    return;
  }
  const ratesCmd = argv.match(/^rates?\s+([a-z]{3,6})\s*(\d+)?$/i);
  if (ratesCmd) {
    const base = resolveCode(ratesCmd[1]);
    if (!base) throw new Error('Unknown currency "' + ratesCmd[1] + '" — /cur codes lists popular ones.');
    const n = Math.min(parseInt(ratesCmd[2], 10) || 12, 25);
    const rates = await getRates(base);
    const entries = Object.entries(rates)
      .filter(([c]) => POPULAR.some(([p]) => p === c))
      .sort((a, b) => a[0].localeCompare(b[0]))
      .slice(0, n);
    say('💱 1 ' + base + ' equals (popular codes):');
    for (const [c, v] of entries) {
      const name = (POPULAR.find(([p]) => p === c) || [])[1] || '';
      say('   ' + c.padEnd(4) + ' ' + fmtAmount(v).padStart(16) + '  ' + name);
    }
    say('   (cached 6h per chat — /cur <amount> <from> to <to> converts)');
    return;
  }
  // conversion: [amount] <from> [to] <to>
  const m = argv.match(/^(?:(\d+(?:[.,]\d+)?)\s*)?([a-z]{3,6})\s*(?:to\s+)?([a-z]{3,6})$/i);
  if (!m) {
    say('Usage: /cur <amount> <from> to <to> — e.g. /cur 250 usd to idr');
    say('       /cur rates <base> · /cur codes · /cur help');
    return;
  }
  const amount = m[1] ? parseFloat(m[1].replace(',', '.')) : 1;
  const from = resolveCode(m[2]);
  const to = resolveCode(m[3]);
  if (!from) throw new Error('Unknown currency "' + m[2] + '" — /cur codes lists popular ones.');
  if (!to) throw new Error('Unknown currency "' + m[3] + '" — /cur codes lists popular ones.');
  const rates = await getRates(from);
  const rate = rates[to];
  if (!rate) throw new Error(to + ' is not available from the rate service for base ' + from + '.');
  const converted = amount * rate;
  const fromName = (POPULAR.find(([p]) => p === from) || [])[1] || from;
  const toName = (POPULAR.find(([p]) => p === to) || [])[1] || to;
  say('💱 ' + fmtAmount(amount) + ' ' + from + (fromName !== from ? ' (' + fromName + ')' : '') +
      ' = ' + fmtAmount(converted) + ' ' + to + (toName !== to ? ' (' + toName + ')' : ''));
  say('   1 ' + from + ' = ' + fmtAmount(rate) + ' ' + to + ' · 1 ' + to + ' = ' +
      fmtAmount(1 / rate) + ' ' + from + ' · mid-market, cached ≤6h');
}

// ================================================================= units

// base-unit factor tables (all factors relative to the SI base)
const UNITS = {
  length: {
    base: 'm',
    table: {
      m: 1, meter: 1, meters: 1, metre: 1, metres: 1,
      km: 1000, kilometer: 1000, kilometers: 1000, kilometre: 1000, kilometres: 1000,
      cm: 0.01, centimeter: 0.01, centimeters: 0.01, centimetre: 0.01, centimetres: 0.01,
      mm: 0.001, millimeter: 0.001, millimeters: 0.001, millimetre: 0.001, millimetres: 0.001,
      um: 1e-6, micron: 1e-6, microns: 1e-6, micrometer: 1e-6, micrometers: 1e-6,
      nm: 1e-9, nanometer: 1e-9, nanometers: 1e-9,
      mi: 1609.344, mile: 1609.344, miles: 1609.344,
      yd: 0.9144, yard: 0.9144, yards: 0.9144,
      ft: 0.3048, foot: 0.3048, feet: 0.3048,
      in: 0.0254, inch: 0.0254, inches: 0.0254,
      nmi: 1852, 'nauticalmile': 1852, 'nauticalmiles': 1852,
      ly: 9.4607304725808e15, lightyear: 9.4607304725808e15, lightyears: 9.4607304725808e15,
      au: 1.495978707e11, lightsecond: 2.99792458e8,
    },
  },
  mass: {
    base: 'kg',
    table: {
      kg: 1, kilogram: 1, kilograms: 1, kilo: 1, kilos: 1,
      g: 0.001, gram: 0.001, grams: 0.001,
      mg: 1e-6, milligram: 1e-6, milligrams: 1e-6,
      t: 1000, ton: 1000, tons: 1000, tonne: 1000, tonnes: 1000,
      lb: 0.45359237, lbs: 0.45359237, pound: 0.45359237, pounds: 0.45359237,
      oz: 0.028349523125, ounce: 0.028349523125, ounces: 0.028349523125,
      st: 6.35029318, stone: 6.35029318, stones: 6.35029318,
      ct: 0.0002, carat: 0.0002, carats: 0.0002,
    },
  },
  data: {
    base: 'B',
    table: {
      b: 1, byte: 1, bytes: 1,
      kb: 1e3, mb: 1e6, gb: 1e9, tb: 1e12, pb: 1e15,
      kilobyte: 1e3, kilobytes: 1e3, megabyte: 1e6, megabytes: 1e6,
      gigabyte: 1e9, gigabytes: 1e9, terabyte: 1e12, terabytes: 1e12,
      kib: 1024, mib: 1024 ** 2, gib: 1024 ** 3, tib: 1024 ** 4,
      kibibyte: 1024, mebibyte: 1024 ** 2, gibibyte: 1024 ** 3, tebibyte: 1024 ** 4,
      bit: 0.125, bits: 0.125, kbit: 125, mbit: 125000, gbit: 125000000,
    },
  },
  speed: {
    base: 'm/s',
    table: {
      'm/s': 1, mps: 1, 'meterspersecond': 1,
      'km/h': 1 / 3.6, kmh: 1 / 3.6, kph: 1 / 3.6, 'kmh2': 1 / 3.6,
      mph: 0.44704, 'mi/h': 0.44704,
      kn: 0.514444, knot: 0.514444, knots: 0.514444, kt: 0.514444,
      'ft/s': 0.3048, fps: 0.3048,
    },
  },
  volume: {
    base: 'L',
    table: {
      l: 1, liter: 1, liters: 1, litre: 1, litres: 1,
      ml: 0.001, milliliter: 0.001, milliliters: 0.001, millilitre: 0.001, millilitres: 0.001,
      cl: 0.01, dl: 0.1,
      m3: 1000, 'm³': 1000, cubicmeter: 1000, cubicmeters: 1000,
      cm3: 0.001, 'cm³': 0.001,
      gal: 3.785411784, gallon: 3.785411784, gallons: 3.785411784,
      qt: 0.946352946, quart: 0.946352946, quarts: 0.946352946,
      pt: 0.473176473, pint: 0.473176473, pints: 0.473176473,
      cup: 0.2365882365, cups: 0.2365882365,
      floz: 0.0295735295625, ounce2: 0.0295735295625,
      tbsp: 0.0147867648, tablespoon: 0.0147867648, tablespoons: 0.0147867648,
      tsp: 0.004928922, teaspoon: 0.004928922, teaspoons: 0.004928922,
    },
  },
  area: {
    base: 'm2',
    table: {
      m2: 1, 'm²': 1, sqm: 1, squaremeter: 1, squaremeters: 1,
      km2: 1e6, 'km²': 1e6, sqkm: 1e6,
      cm2: 1e-4, 'cm²': 1e-4,
      ft2: 0.09290304, sqft: 0.09290304, squarefoot: 0.09290304, squarefeet: 0.09290304,
      in2: 0.00064516, sqin: 0.00064516, squareinch: 0.00064516, squareinches: 0.00064516,
      acre: 4046.8564224, acres: 4046.8564224,
      ha: 10000, hectare: 10000, hectares: 10000,
      mi2: 2589988.110336, sqmi: 2589988.110336, squaremile: 2589988.110336, squaremiles: 2589988.110336,
    },
  },
  time: {
    base: 's',
    table: {
      s: 1, sec: 1, secs: 1, second: 1, seconds: 1,
      ms: 0.001, millisecond: 0.001, milliseconds: 0.001,
      min: 60, mins: 60, minute: 60, minutes: 60,
      h: 3600, hr: 3600, hrs: 3600, hour: 3600, hours: 3600,
      day: 86400, days: 86400, d: 86400,
      week: 604800, weeks: 604800, w: 604800,
      month: 2629800, months: 2629800,
      year: 31557600, years: 31557600, yr: 31557600, yrs: 31557600,
    },
  },
};

const TEMPS = { c: 'c', '°c': 'c', celsius: 'c', celcius: 'c', centigrade: 'c',
                f: 'f', '°f': 'f', fahrenheit: 'f',
                k: 'k', kelvin: 'k' };

function toTemp(v, from, to) {
  let c;
  if (from === 'c') c = v;
  else if (from === 'f') c = (v - 32) * 5 / 9;
  else c = v - 273.15;
  if (to === 'c') return c;
  if (to === 'f') return c * 9 / 5 + 32;
  return c + 273.15;
}

function findUnit(word) {
  const w = String(word || '').toLowerCase().replace(/[\s.]/g, '');
  if (!w) return null;
  if (TEMPS[w]) return { cat: 'temp', key: TEMPS[w], label: word };
  for (const [cat, def] of Object.entries(UNITS)) {
    const t = def.table;
    if (t[w] !== undefined) return { cat: cat, key: w, label: word, factor: t[w] };
  }
  // singular/plural and common squashes
  const tries = [w.replace(/s$/, ''), w.replace(/es$/, ''), w + 's'];
  for (const tw of tries) {
    if (TEMPS[tw]) return { cat: 'temp', key: TEMPS[tw], label: word };
    for (const [cat, def] of Object.entries(UNITS)) {
      if (def.table[tw] !== undefined) return { cat: cat, key: tw, label: word, factor: def.table[tw] };
    }
  }
  return null;
}

async function unitCmd(say, argv) {
  if (!argv || argv === 'help') {
    say('📏 Units — offline converter. Usage: /unit <amount> <from> to <to>');
    say('  /unit 5 km to mi · /unit 180 lb to kg · /unit 72 f to c');
    say('  /unit 1.5 gb to mb · /unit 90 kmh to mph · /unit 2 cups to ml');
    say('  Categories: length · mass · data · speed · volume · area · time · temperature');
    return;
  }
  const m = argv.match(/^(?:(-?\d+(?:[.,]\d+)?)\s*)?(.+?)\s*(?:to|in|into|as)\s+(.+)$/i);
  if (!m) {
    say('Usage: /unit <amount> <from> to <to> — e.g. /unit 5 km to mi');
    return;
  }
  const amount = m[1] ? parseFloat(m[1].replace(',', '.')) : 1;
  const from = findUnit(m[2].trim());
  const to = findUnit(m[3].trim());
  if (!from) throw new Error('Unknown unit "' + m[2].trim() + '" — /unit help lists categories.');
  if (!to) throw new Error('Unknown unit "' + m[3].trim() + '" — /unit help lists categories.');
  if (from.cat !== to.cat) {
    throw new Error('Cannot convert ' + from.cat + ' → ' + to.cat + ' (incompatible categories).');
  }
  let result;
  if (from.cat === 'temp') {
    result = toTemp(amount, from.key, to.key);
  } else {
    result = amount * from.factor / to.factor;
  }
  say('📐 ' + fmtAmount(amount) + ' ' + m[2].trim() + ' = ' + fmtAmount(result) + ' ' + m[3].trim());
  if (from.cat === 'temp' && from.key !== 'c' && to.key !== 'c') {
    say('   (' + fmtAmount(amount) + ' ' + from.key + ' = ' +
        fmtAmount(toTemp(amount, from.key, 'c')) + ' °C)');
  }
}

// -------------------------------------------------------------- helpers

function fmtAmount(x) {
  if (!isFinite(x)) return String(x);
  const abs = Math.abs(x);
  if (abs !== 0 && (abs >= 1e12 || abs < 1e-4)) return x.toExponential(4).replace(/e([+-])(\d)$/, 'e$10$2');
  const s = abs >= 1000 ? x.toFixed(2) : abs >= 1 ? x.toPrecision(7) : x.toPrecision(4);
  return s.replace(/(\.\d*?)0+$/, '$1').replace(/\.$/, '');
}

module.exports = main();
