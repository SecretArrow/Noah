# Currency & Units (sample module)

Two everyday converters behind one module: **live exchange rates** from
the free open.er-api.com endpoint (no API key, no sign-up) and a fully
**offline unit converter** across eight categories.

```
Currency · /cur                      Units · /unit
├─ /cur 100 usd to idr               ├─ /unit 5 km to mi
├─ /cur usd idr   (amount 1)         ├─ /unit 180 lb to kg
├─ /cur rates idr 15  (table)        ├─ /unit 72 f to c
├─ /cur codes       (~40 popular)    ├─ /unit 1.5 gb to mb
└─ /cur help                         ├─ /unit 90 kmh to mph
                                     ├─ /unit 2 cups to ml
                                     └─ /unit help
```

## Network scope — one host, allowlisted

The only network call is `https://open.er-api.com/v6/latest/<BASE>` and
the manifest **locks it** with `"allowedHosts": ["open.er-api.com"]` —
even a compromised module can't phone anywhere else. Responses are
cached per chat with a 6-hour TTL (8 most recent bases kept), so repeated
conversions are instant and rate-service-friendly. Friendly aliases work
(`rupiah`, `euro`, `yen`, `ringgit`, `riyal`…) and any ISO code passes
through; unknown currencies error with the `/cur codes` hint.

## The unit engine — offline by design

Eight categories with SI-base factor tables: **length** (m … light-year),
**mass** (mg … tonnes, lb/oz/stone), **data** (decimal KB…PB *and*
binary KiB…TiB, bits), **speed** (m/s, km/h, mph, knots, fps), **volume**
(L/mL … gallons/cups/tbsp), **area** (m², ft², acres, hectares), **time**
(ms … years) and **temperature** (C/F/K with proper formulas, not
factors). Alias resolution handles plurals (`feet`, `lbs`, `kilos`),
spellings (`metre`/`meter`), symbols (`°c`, `m²`) and squashed input
(`kmh`, `sqft`); the parser also accepts `in`/`into`/`as` instead of
`to`. Category mismatches fail with a clear message instead of a wrong
number.

## Files

- `module.json` — manifest (`network` allowlisted to open.er-api.com,
  `storage` for the rate cache; commands `cur` + `unit`)
- `main.js` — command router + rate client/cache + unit engine

## Try it

1. Install the ZIP: **Settings → Modules → Install module**.
2. `/cur 250 usd to idr`
3. `/cur rates eur 10`
4. `/unit 6.1 ft to cm`
