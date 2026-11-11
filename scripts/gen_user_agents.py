#!/usr/bin/env python3
"""Generates lib/data/user_agents.g.dart for ZAgents (v1.41.5 refresh).

Builds a validated database of exactly 1000 unique, realistic User-Agent
strings (168 desktop + 832 Android) from curated component pools.

v1.41.5 policy (user requirement): every Chromium-based identity carries a
Chromium major of 153 or newer (the currently-supported stable trains:
153..157 — 156 went stable Oct 7 2026, 157 is rolling out; nothing <= 150).
Firefox identities use the newest real trains (150..158 — 158.0 shipped
Oct 13 2026, 158.0.1 Oct 20 2026) plus the two live ESR lines (140.x and
153.x). Safari uses the 26.x/27.x trains. Samsung Internet / Opera /
Vivaldi use their newest real releases paired to a >= 153 Chromium base.

Realism rules enforced here (and re-asserted in Dart tests):
  * every string follows the exact wire format of a real browser;
  * Edge/EdgA majors always equal their bundled Chromium major;
  * Opera desktop OPR majors equal Chromium - 20, Opera Mobile OPR equals
    Chromium - 44 (the real-world offsets the app has always used);
  * Samsung Internet majors pair 1:1 with their bundled Chromium major;
  * phone UAs carry the `Mobile` token, tablet UAs never do;
  * Android versions are plausible for each device model;
  * Firefox on macOS uses the dotted `Mac OS X 10.15` token while
    Chromium/Safari use `10_15_7` (exactly like the real browsers);
  * Firefox desktop rv keeps major.minor (Firefox/153.6 -> rv:153.6,
    Firefox/158.0.1 -> rv:158.0) exactly like the real browser;
  * 32-bit Chrome on 64-bit Windows reports the real `WOW64` token;
  * Firefox on Android never includes a device model (like the real app),
    so its uniqueness space is (Android version, rv);
  * no fabricated exotic vendors (no Huawei Chrome, etc.).

Id note: the v1.38-2025 database (1200-149-era trains) was fully replaced
by this 153+-era database, so persisted picks may point at an id that no
longer carries the same identity — UserAgentManager documents this and
falls back to the first record; the next rotate self-heals the pick.

Run:  python3 scripts/gen_user_agents.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "lib" / "data" / "user_agents.g.dart"

# ----------------------------------------------------------------------------
# Component pools (real browser versions / real model codes only).
# ----------------------------------------------------------------------------

CHROME_MIN = 153                                   # user floor: nothing older
CHROME_MAJORS = list(range(153, 158))              # 153..157 (supported trains)
FIREFOX_MAJORS = list(range(150, 159))             # 150..158 (real trains)
# Firefox ESR point releases (real): 140.10..140.16 and the 153.x line.
FIREFOX_ESR = [f"140.{m}" for m in range(10, 17)] + [f"153.{m}" for m in range(1, 7)]
# Apple Safari versions (real): the 26.x line + the 27.x train.
SAFARI_VERSIONS = [
    "26.0", "26.1", "26.2", "26.3", "26.4", "26.5", "27.0", "27.1",
]
# Opera desktop pairs (Chromium major -> OPR major). The real-world offset
# the app has always shipped: OPR = Chromium - 20.
OPERA_PAIRS = {c: c - 20 for c in CHROME_MAJORS}
OPERA_MOBILE_OFFSET = 44                           # Chromium -> OPR on Android
# Samsung Internet -> bundled Chromium major (newest releases, >= 153).
SAMSUNG_PAIRS = [(31.0, 153), (32.0, 155), (33.0, 157)]
# Vivaldi desktop versions with their Chromium base (>= 153; 8.2 ships 152
# and is therefore excluded by the freshness policy).
VIVALDI_PAIRS = [
    ("8.3.4157.3", 154),
]

WIN = "Windows NT 10.0; Win64; x64"        # Windows 10 and 11 both report 10.0
WIN32_ON_64 = "Windows NT 10.0; WOW64"     # 32-bit Chrome on 64-bit Windows
MAC_CHROMIUM = "Macintosh; Intel Mac OS X 10_15_7"   # Chromium/Safari token
MAC_FIREFOX = "Macintosh; Intel Mac OS X 10.15"      # Firefox token
LINUX = "X11; Linux x86_64"

# ----------------------------------------------------------------------------
# Android device pool: model token in UA -> (display name, allowed Android
# versions, kind). Real model codes only; Huawei is intentionally absent
# (Chrome does not ship there). The pool carries the 2024-2026 flagships.
# ----------------------------------------------------------------------------

PHONE = "phone"
TABLET = "tablet"

ANDROID_DEVICES: dict[str, tuple[str, list[int], str]] = {
    # Samsung phones
    "SM-S938B": ("Samsung Galaxy S25 Ultra", [15, 16, 17], PHONE),
    "SM-S936B": ("Samsung Galaxy S25+", [15, 16, 17], PHONE),
    "SM-S931B": ("Samsung Galaxy S25", [15, 16, 17], PHONE),
    "SM-S928B": ("Samsung Galaxy S24 Ultra", [14, 15, 16], PHONE),
    "SM-S926B": ("Samsung Galaxy S24+", [14, 15, 16], PHONE),
    "SM-S921B": ("Samsung Galaxy S24", [14, 15, 16], PHONE),
    "SM-S918B": ("Samsung Galaxy S23 Ultra", [14, 15, 16], PHONE),
    "SM-S911B": ("Samsung Galaxy S23", [14, 15, 16], PHONE),
    "SM-A556B": ("Samsung Galaxy A55 5G", [14, 15, 16], PHONE),
    "SM-A546B": ("Samsung Galaxy A54 5G", [13, 14, 15], PHONE),
    "SM-A346B": ("Samsung Galaxy A34 5G", [13, 14, 15], PHONE),
    # Google
    "Pixel 10 Pro": ("Google Pixel 10 Pro", [16, 17], PHONE),
    "Pixel 10": ("Google Pixel 10", [16, 17], PHONE),
    "Pixel 9 Pro": ("Google Pixel 9 Pro", [14, 15, 16, 17], PHONE),
    "Pixel 9": ("Google Pixel 9", [14, 15, 16, 17], PHONE),
    "Pixel 9a": ("Google Pixel 9a", [15, 16, 17], PHONE),
    "Pixel 8 Pro": ("Google Pixel 8 Pro", [14, 15, 16], PHONE),
    "Pixel 8": ("Google Pixel 8", [14, 15, 16], PHONE),
    "Pixel 8a": ("Google Pixel 8a", [14, 15, 16], PHONE),
    "Pixel 7 Pro": ("Google Pixel 7 Pro", [13, 14, 15], PHONE),
    "Pixel 7": ("Google Pixel 7", [13, 14, 15], PHONE),
    "Pixel 7a": ("Google Pixel 7a", [13, 14, 15], PHONE),
    "Pixel 6a": ("Google Pixel 6a", [13, 14, 15], PHONE),
    # Xiaomi / Redmi (global model codes)
    "23021RAAEG": ("Xiaomi Redmi Note 12 5G", [13, 14], PHONE),
    "M2101K6G": ("Xiaomi Redmi Note 10 5G", [13, 14], PHONE),
    "2201117TY": ("Xiaomi Redmi 10C", [13, 14], PHONE),
    # OPPO / vivo / realme / OnePlus / Motorola / Nothing / Infinix / TECNO
    "CPH2451": ("OPPO Reno8 Pro 5G", [13, 14], PHONE),
    "CPH2519": ("OPPO Find N2 Flip", [13, 14], PHONE),
    "V2227": ("vivo X90 Pro", [13, 14], PHONE),
    "V2249": ("vivo V25", [13, 14], PHONE),
    "RMX3521": ("realme GT Neo 3", [13, 14], PHONE),
    "RMX3771": ("realme 11 Pro 5G", [13, 14], PHONE),
    "CPH2449": ("OnePlus 11 5G", [13, 14, 15], PHONE),
    "CPH2557": ("OnePlus 12R 5G", [14, 15], PHONE),
    "LE2123": ("OnePlus 9 Pro 5G", [13, 14], PHONE),
    "XT2341-3": ("Motorola Moto G84 5G", [13, 14], PHONE),
    "XT2303-2": ("Motorola Edge 40", [13, 14, 15], PHONE),
    "A063": ("Nothing Phone (1)", [13, 14], PHONE),
    "Infinix X6819": ("Infinix Note 30", [13, 14], PHONE),
    "TECNO KI7": ("TECNO Spark 10", [13, 14], PHONE),
    # Tablets (their UA must NOT contain the Mobile token)
    "SM-X910": ("Samsung Galaxy Tab S9+", [14, 15, 16], TABLET),
    "SM-X710": ("Samsung Galaxy Tab S9", [14, 15, 16], TABLET),
    "SM-X210": ("Samsung Galaxy Tab A9+", [14, 15], TABLET),
    "SM-X200": ("Samsung Galaxy Tab A9", [14, 15], TABLET),
    "Pixel Tablet": ("Google Pixel Tablet", [14, 15, 16], TABLET),
    "23043RP34G": ("Xiaomi Pad 6", [14, 15], TABLET),
}

SAMSUNG_PHONES = [
    m for m, v in ANDROID_DEVICES.items() if v[2] == PHONE and m.startswith("SM-")
]
ALL_PHONES = [m for m, v in ANDROID_DEVICES.items() if v[2] == PHONE]
TABLETS = [m for m, v in ANDROID_DEVICES.items() if v[2] == TABLET]

# ----------------------------------------------------------------------------
# Records
# ----------------------------------------------------------------------------

records: list[dict] = []  # {id, category, browser, label, ua}
_seen: set[str] = set()


def add(category: str, browser: str, label: str, ua: str) -> None:
    if ua in _seen:
        sys.exit(f"FATAL: duplicate UA produced: {ua}")
    _seen.add(ua)
    records.append(
        {
            "id": len(records) + 1,
            "category": category,
            "browser": browser,
            "label": label,
            "ua": ua,
        }
    )


def chromium_ua(platform: str, chrome: int, extra: str = "") -> str:
    tail = f" {extra}" if extra else ""
    return (
        f"Mozilla/5.0 ({platform}) AppleWebKit/537.36 (KHTML, like Gecko) "
        f"Chrome/{chrome}.0.0.0 Safari/537.36{tail}"
    )


def firefox_desktop_ua(platform_dots: str, version: str) -> str:
    return (
        f"Mozilla/5.0 ({platform_dots}; rv:{version.split('.')[0]}.0) "
        f"Gecko/20100101 Firefox/{version}"
    )


def firefox_esr_ua(platform_dots: str, version: str) -> str:
    # Real ESR rule: rv keeps major.minor (Firefox/153.6 -> rv:153.6).
    rv = ".".join(version.split(".")[:2])
    return f"Mozilla/5.0 ({platform_dots}; rv:{rv}) Gecko/20100101 Firefox/{version}"


def android_ua(model: str, android: int, chrome: int, extra: str = "") -> str:
    kind = ANDROID_DEVICES[model][2]
    mobile = "Mobile " if kind == PHONE else ""
    tail = f" {extra}" if extra else ""
    return (
        f"Mozilla/5.0 (Linux; Android {android}; {model}) AppleWebKit/537.36 "
        f"(KHTML, like Gecko) Chrome/{chrome}.0.0.0 {mobile}Safari/537.36{tail}"
    )


def interleave(groups):
    """Round-robin across per-model combo lists for a natural spread."""
    out = []
    idx = 0
    total = sum(len(g) for g in groups)
    while len(out) < total:
        for g in groups:
            if idx < len(g):
                out.append(g[idx])
        idx += 1
    return out


# ----------------------------- DESKTOP (168) --------------------------------

# Chrome desktop — 20: one record per supported train per platform token
# (Win64, WOW64 32-bit, macOS, Linux).
for major in CHROME_MAJORS:
    add("desktop", "chrome", f"Chrome {major} · Windows 10/11", chromium_ua(WIN, major))
for major in CHROME_MAJORS:
    add("desktop", "chrome", f"Chrome {major} · Windows 10/11 (32-bit)",
        chromium_ua(WIN32_ON_64, major))
for major in CHROME_MAJORS:
    add("desktop", "chrome", f"Chrome {major} · macOS", chromium_ua(MAC_CHROMIUM, major))
for major in CHROME_MAJORS:
    add("desktop", "chrome", f"Chrome {major} · Linux", chromium_ua(LINUX, major))

# Edge desktop — 20 (Edge major always equals its Chromium major).
for major in CHROME_MAJORS:
    add("desktop", "edge", f"Edge {major} · Windows 10/11",
        chromium_ua(WIN, major, f"Edg/{major}.0.0.0"))
for major in CHROME_MAJORS:
    add("desktop", "edge", f"Edge {major} · Windows 10/11 (32-bit)",
        chromium_ua(WIN32_ON_64, major, f"Edg/{major}.0.0.0"))
for major in CHROME_MAJORS:
    add("desktop", "edge", f"Edge {major} · macOS",
        chromium_ua(MAC_CHROMIUM, major, f"Edg/{major}.0.0.0"))
for major in CHROME_MAJORS:
    add("desktop", "edge", f"Edge {major} · Linux",
        chromium_ua(LINUX, major, f"Edg/{major}.0.0.0"))

# Opera desktop — 15 (OPR bundles a specific Chromium, OPR = Chromium - 20).
for chrome, opr in OPERA_PAIRS.items():            # 5 Windows
    add("desktop", "opera", f"Opera {opr} (Chromium {chrome}) · Windows 10/11",
        chromium_ua(WIN, chrome, f"OPR/{opr}.0.0.0"))
for chrome, opr in OPERA_PAIRS.items():            # 5 macOS
    add("desktop", "opera", f"Opera {opr} (Chromium {chrome}) · macOS",
        chromium_ua(MAC_CHROMIUM, chrome, f"OPR/{opr}.0.0.0"))
for chrome, opr in OPERA_PAIRS.items():            # 5 Linux
    add("desktop", "opera", f"Opera {opr} (Chromium {chrome}) · Linux",
        chromium_ua(LINUX, chrome, f"OPR/{opr}.0.0.0"))

# Vivaldi desktop — 3.
for vivaldi, chrome in VIVALDI_PAIRS:
    short = ".".join(vivaldi.split(".")[:2])
    add("desktop", "vivaldi", f"Vivaldi {short} · Windows 10/11",
        chromium_ua(WIN, chrome, f"Vivaldi/{vivaldi}"))
    add("desktop", "vivaldi", f"Vivaldi {short} · macOS",
        chromium_ua(MAC_CHROMIUM, chrome, f"Vivaldi/{vivaldi}"))
    add("desktop", "vivaldi", f"Vivaldi {short} · Linux",
        chromium_ua(LINUX, chrome, f"Vivaldi/{vivaldi}"))

# Firefox desktop — 102 (point releases are real: Firefox ships .0.1/.0.2
# fixes; rv keeps major.minor, exactly like the real browser).
for major in FIREFOX_MAJORS:                       # 27 Windows (.0/.0.1/.0.2)
    add("desktop", "firefox", f"Firefox {major}.0 · Windows 10/11",
        firefox_desktop_ua(WIN, f"{major}.0"))
    add("desktop", "firefox", f"Firefox {major}.0.1 · Windows 10/11",
        firefox_desktop_ua(WIN, f"{major}.0.1"))
    add("desktop", "firefox", f"Firefox {major}.0.2 · Windows 10/11",
        firefox_desktop_ua(WIN, f"{major}.0.2"))
for major in FIREFOX_MAJORS:                       # 18 macOS (.0/.0.1)
    add("desktop", "firefox", f"Firefox {major}.0 · macOS",
        firefox_desktop_ua(MAC_FIREFOX, f"{major}.0"))
    add("desktop", "firefox", f"Firefox {major}.0.1 · macOS",
        firefox_desktop_ua(MAC_FIREFOX, f"{major}.0.1"))
for major in FIREFOX_MAJORS:                       # 18 Linux (.0/.0.1)
    add("desktop", "firefox", f"Firefox {major}.0 · Linux",
        firefox_desktop_ua(LINUX, f"{major}.0"))
    add("desktop", "firefox", f"Firefox {major}.0.1 · Linux",
        firefox_desktop_ua(LINUX, f"{major}.0.1"))
for v in FIREFOX_ESR:                              # 39 ESR point releases
    add("desktop", "firefox", f"Firefox ESR {v} · Windows 10/11",
        firefox_esr_ua(WIN, v))
    add("desktop", "firefox", f"Firefox ESR {v} · macOS", firefox_esr_ua(MAC_FIREFOX, v))
    add("desktop", "firefox", f"Firefox ESR {v} · Linux", firefox_esr_ua(LINUX, v))

# Safari macOS — 8 (Safari still reports the frozen 10_15_7 token).
for v in SAFARI_VERSIONS:
    add("desktop", "safari", f"Safari {v} · macOS",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        f"(KHTML, like Gecko) Version/{v} Safari/605.1.15")

assert len(records) == 168, f"desktop count = {len(records)}"

# ----------------------------- ANDROID (832) ---------------------------------

android_before = len(records)
assert android_before == 168

# Chrome phone — 360: round-robin over every phone model.
groups = []
for model in ALL_PHONES:
    androids = ANDROID_DEVICES[model][1]
    combos = [
        (model, androids[i % len(androids)], CHROME_MAJORS[(i * 7) % len(CHROME_MAJORS)])
        for i in range(24 * len(androids))
    ]
    groups.append(combos)
seen_combo: set[tuple] = set()
count = 0
for model, android, chrome in interleave(groups):
    if count >= 360:
        break
    guard = 0
    while (model, android, chrome) in seen_combo:
        guard += 1
        if guard > len(CHROME_MAJORS):
            break
        chrome = CHROME_MAJORS[(CHROME_MAJORS.index(chrome) + 1) % len(CHROME_MAJORS)]
    if (model, android, chrome) in seen_combo:
        continue
    seen_combo.add((model, android, chrome))
    name = ANDROID_DEVICES[model][0]
    add("android", "chrome", f"Chrome {chrome} · {name} (Android {android})",
        android_ua(model, android, chrome))
    count += 1
assert count == 360, f"chrome phone = {count}"

# Chrome tablet — 60: no Mobile token (exactly like real Android tablets).
groups = []
for model in TABLETS:
    androids = ANDROID_DEVICES[model][1]
    combos = [
        (model, androids[i % len(androids)], CHROME_MAJORS[(i * 7) % len(CHROME_MAJORS)])
        for i in range(24 * len(androids))
    ]
    groups.append(combos)
seen_combo.clear()
count = 0
for model, android, chrome in interleave(groups):
    if count >= 60:
        break
    guard = 0
    while (model, android, chrome) in seen_combo:
        guard += 1
        if guard > len(CHROME_MAJORS):
            break
        chrome = CHROME_MAJORS[(CHROME_MAJORS.index(chrome) + 1) % len(CHROME_MAJORS)]
    if (model, android, chrome) in seen_combo:
        continue
    seen_combo.add((model, android, chrome))
    name = ANDROID_DEVICES[model][0]
    add("android", "chrome", f"Chrome {chrome} · {name} (Android {android})",
        android_ua(model, android, chrome))
    count += 1
assert count == 60, f"chrome tablet = {count}"

# Samsung Internet — 58 (real bundled Chromium majors, >= 153).
groups = []
for model in SAMSUNG_PHONES:
    combos = [
        (model, android, sb)
        for android in ANDROID_DEVICES[model][1]
        for sb, _ in SAMSUNG_PAIRS
    ]
    groups.append(combos)
samsung_chrome = {int(s): c for s, c in SAMSUNG_PAIRS}
candidates = [c for c in interleave(groups)]
count = 0
used_samsung: set[tuple] = set()
for model, android, sb in candidates:
    if count >= 58:
        break
    if (model, android, sb) in used_samsung:
        continue
    used_samsung.add((model, android, sb))
    chrome = samsung_chrome[int(sb)]
    name = ANDROID_DEVICES[model][0]
    add("android", "samsungInternet",
        f"Samsung Internet {sb:.0f} · {name} (Android {android})",
        f"Mozilla/5.0 (Linux; Android {android}; {model}) AppleWebKit/537.36 "
        f"(KHTML, like Gecko) SamsungBrowser/{sb:.0f}.0 Chrome/{chrome}.0.0.0 "
        f"Mobile Safari/537.36")
    count += 1
assert count == 58, f"samsung = {count}"

# Firefox Android — 54 (36 phone + 18 tablet, real Gecko format).
# NOTE: Firefox on Android does NOT put the device model in its UA, so the
# uniqueness space is (Android version, rv). Labels name a plausible
# representative device for each Android version.
FF_PHONE_MODEL = {14: "Pixel 8", 15: "Pixel 9", 16: "Pixel 9 Pro", 17: "Pixel 10"}
count = 0
for rv in FIREFOX_MAJORS:
    for android in (14, 15, 16, 17):
        if count >= 36:
            break
        model = FF_PHONE_MODEL[android]
        name = ANDROID_DEVICES[model][0]
        add("android", "firefox", f"Firefox {rv} · {name} (Android {android})",
            f"Mozilla/5.0 (Android {android}; Mobile; rv:{rv}.0) Gecko/{rv}.0 "
            f"Firefox/{rv}.0")
        count += 1
assert count == 36, f"firefox phone = {count}"
FF_TABLET_MODEL = {15: "Pixel Tablet", 16: "SM-X910"}
count = 0
for rv in FIREFOX_MAJORS:
    for android in (15, 16):
        if count >= 18:
            break
        model = FF_TABLET_MODEL[android]
        name = ANDROID_DEVICES[model][0]
        add("android", "firefox", f"Firefox {rv} · {name} (Android {android})",
            f"Mozilla/5.0 (Android {android}; Tablet; rv:{rv}.0) Gecko/{rv}.0 "
            f"Firefox/{rv}.0")
        count += 1
assert count == 18, f"firefox tablet = {count}"

# Edge Android — 150 (EdgA major == Chromium major).
edge_models = [
    "SM-S931B", "SM-S921B", "Pixel 10 Pro", "Pixel 8 Pro", "SM-A546B",
    "Pixel 7", "CPH2451", "V2249", "RMX3771", "CPH2449", "Pixel 8a",
    "SM-A556B", "Pixel 9", "CPH2557", "XT2303-2",
]
groups = []
for model in edge_models:
    androids = ANDROID_DEVICES[model][1]
    combos = [
        (model, androids[i % len(androids)], CHROME_MAJORS[(i * 3) % len(CHROME_MAJORS)])
        for i in range(24 * len(androids))
    ]
    groups.append(combos)
seen_combo.clear()
count = 0
for model, android, chrome in interleave(groups):
    if count >= 150:
        break
    if (model, android, chrome) in seen_combo:
        continue
    seen_combo.add((model, android, chrome))
    name = ANDROID_DEVICES[model][0]
    add("android", "edge", f"Edge {chrome} · {name} (Android {android})",
        android_ua(model, android, chrome, f"EdgA/{chrome}.0.0.0"))
    count += 1
assert count == 150, f"edge android = {count}"

# Opera Mobile — 150 (OPR = Chromium - 44, real-world offset).
opera_models = [
    "SM-S938B", "Pixel 9", "SM-A346B", "Pixel 7a", "23021RAAEG",
    "CPH2519", "RMX3521", "XT2341-3", "V2227", "Pixel 6a", "Pixel 9a",
    "SM-S936B", "M2101K6G", "A063", "Infinix X6819",
]
groups = []
for model in opera_models:
    androids = ANDROID_DEVICES[model][1]
    combos = [
        (model, androids[i % len(androids)], CHROME_MAJORS[(i * 7) % len(CHROME_MAJORS)])
        for i in range(24 * len(androids))
    ]
    groups.append(combos)
seen_combo.clear()
count = 0
for model, android, chrome in interleave(groups):
    if count >= 150:
        break
    guard = 0
    while (model, android, chrome) in seen_combo:
        guard += 1
        if guard > len(CHROME_MAJORS):
            break
        chrome = CHROME_MAJORS[(CHROME_MAJORS.index(chrome) + 1) % len(CHROME_MAJORS)]
    if (model, android, chrome) in seen_combo:
        continue
    seen_combo.add((model, android, chrome))
    opr = chrome - OPERA_MOBILE_OFFSET
    name = ANDROID_DEVICES[model][0]
    add("android", "opera", f"Opera {opr} · {name} (Android {android})",
        android_ua(model, android, chrome, f"OPR/{opr}.0.0.0"))
    count += 1
assert count == 150, f"opera android = {count}"

android_count = len(records) - android_before
assert android_count == 832, f"android count = {android_count}"

# ----------------------------------------------------------------------------
# Validation (mirrored in test/unit/user_agent_test.dart)
# ----------------------------------------------------------------------------

R_CHROME_DESKTOP = re.compile(
    r"^Mozilla/5\.0 \((?P<plat>Windows NT 10\.0; Win64; x64|Windows NT 10\.0; WOW64|Macintosh; "
    r"Intel Mac OS X 10_15_7|X11; Linux x86_64)\) AppleWebKit/537\.36 "
    r"\(KHTML, like Gecko\) Chrome/(?P<c>\d+)\.0\.0\.0 Safari/537\.36"
)
R_EDGE_DESKTOP = re.compile(R_CHROME_DESKTOP.pattern + r" Edg/(?P<e>\d+)\.0\.0\.0$")
R_FIREFOX_DESKTOP = re.compile(
    r"^Mozilla/5\.0 \((?P<plat>Windows NT 10\.0; Win64; x64|Macintosh; "
    r"Intel Mac OS X 10\.15|X11; Linux x86_64); rv:(?P<rv>\d+\.\d+)\) Gecko/20100101 "
    r"Firefox/(?P<f>\d+\.\d+(\.\d+)?)$"
)
R_SAFARI = re.compile(
    r"^Mozilla/5\.0 \(Macintosh; Intel Mac OS X 10_15_7\) "
    r"AppleWebKit/605\.1\.15 \(KHTML, like Gecko\) Version/\d+\.\d+ "
    r"Safari/605\.1\.15$"
)
R_OPERA_DESKTOP = re.compile(R_CHROME_DESKTOP.pattern + r" OPR/(?P<o>\d+)\.0\.0\.0$")
R_VIVALDI_DESKTOP = re.compile(
    R_CHROME_DESKTOP.pattern + r" Vivaldi/\d+\.\d+\.\d+\.\d+$"
)
R_CHROME_ANDROID = re.compile(
    r"^Mozilla/5\.0 \(Linux; Android (?P<a>\d+); (?P<model>[^)]+)\) "
    r"AppleWebKit/537\.36 \(KHTML, like Gecko\) Chrome/(?P<c>\d+)\.0\.0\.0 "
    r"(?P<mobile>Mobile )?Safari/537\.36$"
)
R_SAMSUNG = re.compile(
    r"^Mozilla/5\.0 \(Linux; Android (?P<a>\d+); (?P<model>SM-[^)]+)\) "
    r"AppleWebKit/537\.36 \(KHTML, like Gecko\) SamsungBrowser/(?P<s>\d+)\.0 "
    r"Chrome/(?P<c>\d+)\.0\.0\.0 Mobile Safari/537\.36$"
)
R_FIREFOX_ANDROID = re.compile(
    r"^Mozilla/5\.0 \(Android (?P<a>\d+); (?P<kind>Mobile|Tablet); "
    r"rv:(?P<rv>\d+)\.0\) Gecko/(?P=rv)\.0 Firefox/(?P<f>\d+)\.0$"
)
R_EDGE_ANDROID = re.compile(
    R_CHROME_ANDROID.pattern[:-1] + r" EdgA/(?P<e>\d+)\.0\.0\.0$"
)
R_OPERA_ANDROID = re.compile(
    R_CHROME_ANDROID.pattern[:-1] + r" OPR/(?P<o>\d+)\.0\.0\.0$"
)

SAMSUNG_CHROME_MAP = {int(s): c for s, c in SAMSUNG_PAIRS}

CHROMIUM_TOKEN_MIN = CHROME_MIN  # every Chrome/NNN token must be >= 153

for r in records:
    ua = r["ua"]
    cat, browser = r["category"], r["browser"]
    if cat == "desktop":
        if browser == "chrome":
            assert R_CHROME_DESKTOP.match(ua), ua
        elif browser == "edge":
            m = R_EDGE_DESKTOP.match(ua)
            assert m and m.group("e") == m.group("c"), ua
        elif browser == "firefox":
            m = R_FIREFOX_DESKTOP.match(ua)
            assert m, ua
            # rv keeps major.minor (Firefox/153.6 -> rv:153.6,
            # Firefox/158.0.1 -> rv:158.0) — the real Firefox rule.
            assert ".".join(m.group("f").split(".")[:2]) == m.group("rv"), ua
        elif browser == "safari":
            assert R_SAFARI.match(ua), ua
        elif browser == "opera":
            m = R_OPERA_DESKTOP.match(ua)
            # Real-world offset used everywhere: OPR = Chromium - 20.
            assert m and int(m.group("o")) == int(m.group("c")) - 20, ua
        elif browser == "vivaldi":
            assert R_VIVALDI_DESKTOP.match(ua), ua
        else:
            sys.exit(f"unknown desktop browser {browser}")
    else:
        if browser == "chrome":
            m = R_CHROME_ANDROID.match(ua)
            assert m, ua
            model = m.group("model")
            assert model in ANDROID_DEVICES, f"unknown model: {ua}"
            kind = ANDROID_DEVICES[model][2]
            assert (m.group("mobile") == "Mobile ") == (kind == PHONE), ua
            assert int(m.group("a")) in ANDROID_DEVICES[model][1], ua
        elif browser == "samsungInternet":
            m = R_SAMSUNG.match(ua)
            assert m, ua
            assert SAMSUNG_CHROME_MAP[int(m.group("s"))] == int(m.group("c")), ua
            assert int(m.group("a")) in ANDROID_DEVICES[m.group("model")][1], ua
        elif browser == "firefox":
            m = R_FIREFOX_ANDROID.match(ua)
            assert m and m.group("f") == m.group("rv"), ua
        elif browser == "edge":
            m = R_EDGE_ANDROID.match(ua)
            assert m and m.group("e") == m.group("c"), ua
            assert m.group("mobile") == "Mobile ", ua
            assert int(m.group("a")) in ANDROID_DEVICES[m.group("model")][1], ua
        elif browser == "opera":
            m = R_OPERA_ANDROID.match(ua)
            assert m and int(m.group("o")) == int(m.group("c")) - OPERA_MOBILE_OFFSET, ua
            assert m.group("mobile") == "Mobile ", ua
            assert int(m.group("a")) in ANDROID_DEVICES[m.group("model")][1], ua
        else:
            sys.exit(f"unknown android browser {browser}")

    # The v1.41.5 freshness policy: every Chromium token >= 153.
    for tok in re.findall(r"Chrome/(\d+)\.0\.0\.0", ua):
        assert int(tok) >= CHROMIUM_TOKEN_MIN, f"stale Chromium {tok}: {ua}"

assert len({r["ua"] for r in records}) == 1000, "UA strings must be globally unique"
assert len({r["id"] for r in records}) == 1000
assert sum(1 for r in records if r["category"] == "desktop") == 168
assert sum(1 for r in records if r["category"] == "android") == 832
assert len({r["label"] for r in records}) == 1000, "labels must be unique"

# Spot checks: the exact records at fixed ids (regeneration drift guard).
SPOT_CHECKS = {
    1: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36",
    5: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/157.0.0.0 Safari/537.36",
    21: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36 Edg/153.0.0.0",
    100: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:157.0) Gecko/20100101 Firefox/157.0",
    168: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.1 Safari/605.1.15",
}
for sid, sua in SPOT_CHECKS.items():
    got = next(r for r in records if r["id"] == sid)
    assert got["ua"] == sua, f"spot id {sid} drifted:\n  got:  {got['ua']}\n  want: {sua}"

# ----------------------------------------------------------------------------
# Emit Dart
# ----------------------------------------------------------------------------


def dart_str(s: str) -> str:
    return s.replace("\\", "\\\\").replace("'", "\\'")


BROWSER_ENUM = {
    "chrome": "UserAgentBrowser.chrome",
    "edge": "UserAgentBrowser.edge",
    "firefox": "UserAgentBrowser.firefox",
    "safari": "UserAgentBrowser.safari",
    "opera": "UserAgentBrowser.opera",
    "samsungInternet": "UserAgentBrowser.samsungInternet",
    "vivaldi": "UserAgentBrowser.vivaldi",
}

lines = [
    "// GENERATED FILE — do not edit by hand.",
    "// Regenerate with: python3 scripts/gen_user_agents.py",
    "//",
    "// Database of 1000 unique, realistic User-Agent strings (168 desktop +",
    "// 832 Android) composed from curated pools of real browser versions and",
    "// real device model codes. Every entry is format-validated against the",
    "// wire format of the browser it represents (see scripts/gen_user_agents.py",
    "// and test/unit/user_agent_test.dart for the enforced rules).",
    "// v1.41.5 freshness policy: every Chromium token is 153+ (supported",
    "// trains only), Firefox 150..158 + live ESR, Safari 26.x/27.x.",
    "import '../models/user_agent.dart';",
    "",
    "/// 1000 validated User-Agent records: 168 desktop + 832 Android.",
    "const List<UserAgentRecord> kUserAgentDatabase = <UserAgentRecord>[",
]
for r in records:
    lines.append(
        "  UserAgentRecord(\n"
        f"    id: {r['id']},\n"
        f"    category: UserAgentCategory.{r['category']},\n"
        f"    browser: {BROWSER_ENUM[r['browser']]},\n"
        f"    label: '{dart_str(r['label'])}',\n"
        f"    ua: '{dart_str(r['ua'])}',\n"
        "  ),"
    )
lines.append("];")
lines.append("")

OUT.parent.mkdir(parents=True, exist_ok=True)
OUT.write_text("\n".join(lines), encoding="utf-8")

by_family: dict[str, int] = {}
for r in records:
    key = f"{r['category']}/{r['browser']}"
    by_family[key] = by_family.get(key, 0) + 1
print(f"OK: wrote {len(records)} records to {OUT}")
for k in sorted(by_family):
    print(f"  {k}: {by_family[k]}")
