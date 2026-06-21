# Tidbyt air-quality app — design for 766 S Martin St

A Pixlet app for the Tidbyt that shows current conditions plus today + tomorrow forecast, prioritizing the Longmont – Municipal (LNGM) regulatory monitor at 350 Kimbark St. as the primary point observation.

## Platform constraints (Pixlet / Tidbyt)

- **Display:** 64×32 RGB matrix. ~12–14 chars per line at the default `tb-8` font (8 px tall, variable width). Practical: 4 stacked lines or 2 tall + accents.
- **Language:** Starlark via [Pixlet](https://github.com/tidbyt/pixlet) — Python-like but pure (no I/O outside whitelisted modules).
- **Render tree:** `main(config)` returns a `render.Root(child=…)` with widgets like `Box`, `Row`, `Column`, `Stack`, `Text`, `WrappedText`, `Marquee`, `Padding`, `Plot`, `Image`, `Animation`.
- **Animation:** the entire frame can rotate through an `Animation` of sub-frames; alternately, the Tidbyt rotates between *apps* every ~10 s, so a single static composite frame is also valid.
- **HTTP:** `http.get(url, ttl_seconds=N)` — built-in response cache, key is the URL. TTL is what protects upstream APIs and Tidbyt's render budget.
- **Schema:** user-configurable fields (Text, Toggle, Dropdown, Color, Location, DateTime, Generated, OAuth2). Location field returns `{lat, lng, description, locality, timezone}`. For a personal app the location can be hard-coded.
- **Secrets:** for a private push, embed the API key directly in the .star file. For a community app, wrap with `pixlet encrypt` so the key is sealed against Tidbyt's public key.
- **Deployment:** `pixlet push --installation-id longmont-aq` for personal rotation; community submission for public.

## Data sources, in priority order

After confirming BoulderAIR exposes a live JSONP feed (see [research-notes.md](../research-notes.md), "BoulderAIR" subsection), LUR replaces AirNow as the primary obs source — it's closer to S Martin St (~6 km vs. 28 km), updates every ~5 min, and carries pollutants AirNow doesn't.

| Use | Source | Why this and not the alternative |
| --- | --- | --- |
| Current PM2.5, PM10, O3, NO2, CH4 at this address | **BoulderAIR LUR JSONP** — `https://www.bouldair.com/webdata/LUR/json/LUR_<meas>_stats.json` | LUR (Longmont Union Reservoir) is a research-grade BoulderAIR site ~6 km NE of 766 S Martin St — by far the closest real monitor. Carries pm / o3 / met (incl. NO/NO2/NOx) / voc / ch4. Today's spot reading (O3 71.5 ppb) matches AirNow's Westminster-monitor AQI 71 within rounding, confirming LUR is well calibrated. |
| Backup current PM/O3 if LUR is down | **AirNow `/aq/observation/latLong/current/`** with `distance=25` | Regulatory rollup; returns the nearest reporting monitor (Denver-Boulder area). Use only if LUR returns stale or empty. |
| Today + tomorrow forecast | **AirNow `/aq/forecast/latLong/`** at S Martin St coords | This is the CDPHE forecast surfaced verbatim (`forecastAgency: "Colorado Department of Public Health and Environment"`). Returns one row per pollutant (PM2.5, OZONE) per day, with `categoryName` and `actionDay`. BoulderAIR has no forecast. |
| Action Day advisory | Same forecast response — `actionDay: true/false` per row | First-class field, no second call needed. |
| LNGM (CDPHE regulatory) cross-check | **AirNow `/aq/data/?`** with bbox around LNGM | Optional. Worth including for the "what does the regulatory monitor at 350 Kimbark St. say right now" cross-check. Only PM10/PM2.5 (per CDPHE site_description). |
| CAMS sanity check (optional, v2) | **Open-Meteo `/v1/air-quality`** | A second opinion for trends and forecast spikes. Skip in v1 to keep the call count low. |

Skipped sources and why:

- **IQAir / WAQI / Plume:** proprietary fusion, can't tell which monitor you're seeing.
- **PurpleAir:** PM2.5-only, biased without EPA Barkjohn correction. Could be a v3 layer for hyperlocal cross-check.
- **LLG** (BoulderAIR's other Longmont site, ~10 km W): only carries O3, met, CH4 — no PM, no VOC. Strictly inferior to LUR for this address. Worth knowing about as a backup if LUR ever drops O3.

### BoulderAIR LUR endpoint catalog

| Endpoint | Fields (`head`) | What you get from `curMinMaxAvg` |
| --- | --- | --- |
| `LUR_pm_stats.json` | `time, pm10, pm2_5` | Current/min/max/avg in µg/m³. Today's current PM2.5 = 10.2, PM10 = 24.4. |
| `LUR_o3_stats.json` | `time, o3` | Current/min/max/avg in ppb. Today's current = 71.5. |
| `LUR_met_stats.json` | `time, solr, temp_f, relh, wsp_avg_ms, wdr_avg, ptemp_f, tempinstr_f, no, nox, no2, pressure_ECC, water_vapor_mr` | Weather + NOx species. Note: `no/nox/no2` live in the *met* file, not their own NOx file. |
| `LUR_voc_stats.json` | 33 VOCs incl. ethane, propane, benzene, toluene, n-pentane, isoprene | Concentrations in ppb. Useful for an oil-and-gas exposure alert. |
| `LUR_ch4_stats.json` | `time, co2_ppm, ch4, h2o_sync` | Greenhouse gases. CH4 today = 2040 ppb (vs. ~1900 background — mild plume). |
| `LUR_<meas>_3day.json` | Same `head` as `_stats`; arrays of sampled values + a `time` column | Full 3-day timeseries — use for `render.Plot` sparklines. |

All files are JSONP-wrapped (`var LUR_<meas>_stats = {…}`). To parse in Starlark:

```python
body = http.get(url, ttl_seconds=300).body()
data = json.decode(body[body.index("{"):body.rindex("}") + 1])
```

The `t9` field is the latest sample epoch in UTC seconds — useful for staleness checks.

## Schema (user-configurable surface)

Personal install can hard-code most of this. For a community-app version:

```python
def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Location(
                id = "location",
                name = "Location",
                desc = "Address to monitor.",
                icon = "locationDot",
            ),
            schema.Text(
                id = "airnow_api_key",
                name = "AirNow API key",
                desc = "Free key from airnowapi.org.",
                icon = "key",
            ),
            schema.Dropdown(
                id = "primary_monitor_aqs_id",
                name = "Primary monitor AQS ID",
                desc = "Preferred regulatory site. Leave blank to pick the nearest.",
                icon = "satelliteDish",
                default = "080130003",  # LNGM
                options = [
                    schema.Option(display = "Longmont – Municipal (Kimbark)", value = "080130003"),
                    schema.Option(display = "Boulder – CU/Athens",            value = "080131001"),
                    schema.Option(display = "Auto (nearest)",                 value = ""),
                ],
            ),
            schema.Toggle(
                id = "show_forecast",
                name = "Show tomorrow's forecast",
                desc = "Rotate to a second frame with tomorrow's category.",
                default = True,
                icon = "calendar",
            ),
        ],
    )
```

## Display — Layout A: single composite frame

Initial sketch (kept here for context; the v1.1 revision below is what's actually shipping):

```
┌────────────────────────────────────────────────┐ 64 wide
│ LNGM 11AM       ! ACTION ! (red, if active)    │ 8 px header
│ ┌────────────┐  PM2.5  59  Mod                 │
│ │            │  PM10   35  Good                │
│ │    59      │  O3     71  Mod                 │
│ │            │                                 │
│ └────────────┘  Tdy Mod·Mod  Tmr Mod·Mod       │ 8 px footer
└────────────────────────────────────────────────┘ 32 tall
```

### Layout A — v1.1 (post-photo critique, 2026-06-21)

Photo of the rendered v1 frame revealed: (1) the "Tdy Mod Tmr Mod" forecast row was truncated to `Tdy Mod T` because tom-thumb at 4 px/char fits ~9 chars in 36 px; (2) the `6x13` big-tile number used only ~25% of the tile area, leaving lots of dead yellow; (3) the under-tile pollutant label was too small to read from any distance; (4) the `LUR 1:30PM` header consumed 7 px of vertical real estate for a freshness indicator that's both hard to read and rarely actionable.

v1.1 changes:

- **Drop the header row entirely.** Standard practice on compact AQ displays — the timestamp isn't useful at a glance and burns 7 px (~22% of the body). Reclaim it for data.
- **Bigger big-tile number.** Switch from `6x13` to `10x20` font (with `6x13` fallback for 3-digit AQI ≥ 100, which would otherwise clip in a 28 px tile).
- **Pollutant label moves into the tile as a top-left badge.** Uses 3-char abbreviations (`P25`, `P10`, `O3`) so it fits alongside an optional alert in the top-right corner. The smoke alert is a 5×7 pixel-art flame (yellow→orange→red gradient); the Action-Day alert is a small `ACT` text badge.
- **Forecast row → two colored squares.** `T▮ M▮` with each square colored by the AirNow forecast category for that day. Fits the column width comfortably and reads faster than the original `Tdy Mod Tmr Mod`.
- **Per-pollutant rows unchanged.** Label / AQI / category short still costs 1 row of tom-thumb each; was already fitting in v1.

```
┌────────────┬─────────────────────────────────┐
│ O3   [SMK] │ PM2.5  33  Gd                   │
│            │ PM10   15  Gd                   │
│    65      │ O3     65  Mod                  │
│            │                                 │
│            │ T▮   M▮                         │
└────────────┴─────────────────────────────────┘
  28×32 left      36×32 right (incl. 2 px pad)
```

### Layout A — v1.2 (post-second-photo critique, 2026-06-21)

Second photo (Layout v1.1, AQI 91 dominant) revealed the layout was still doing too much work per row: the per-pollutant `Gd`/`Mod` text duplicated the color encoding, the `P10` abbreviation in the tile corner duplicated information already visible in the matching right-column row, and the `T`/`M` forecast labels weren't obvious enough. Tightened in v1.2:

- **Drop category words from the right column.** Color encodes category; the text was redundant and crowded the row. Each row is now `LABEL` (white, left) ⋯ `AQI` (color-coded, right) with empty space between. Trade-off documented in [README.md](./README.md) as an accessibility note — color-only encoding is unfriendly to color-blind users; acceptable for a personal app.
- **Drop the dominant-pollutant label from the big tile.** The right column already shows each pollutant's AQI; the user matches the big number to a row to identify the dominant. The tile is now just a centered big number on a category-colored background, with an alert badge appearing in the top-right corner only when smoke or an Action Day is active.
- **Forecast labels: weekday names instead of `T`/`M`.** `Su▮ Mo▮` (computed from `time.now()`) for Sunday/Monday respectively. Each label is unambiguous on its own, so no key is needed.
- **3-digit AQI behavior.** The tile uses a `10x20` font for 2 digits (visually striking) and a `6x13` fallback for 3 digits (since `10x20` "100" is 30 px wide in a 28 px tile). The size discontinuity at the AQI=100 boundary is intentional — that's also the Moderate→USG category boundary, so the visual change reinforces the category change.
- **O3 8-hour rolling mean** was wired in for v1.1 (see "Open questions" below for why); v1.2 keeps that.

## Display — Layout B: 3-frame animation

If you prefer pages over density, an `Animation` of 3 sub-frames:

| Frame | Duration | Content |
| --- | --- | --- |
| **Now** | ~4 s | Big AQI number, dominant pollutant label, "LNGM" attribution |
| **Today / Tomorrow** | ~4 s | Two rows: `TODAY  PM2.5 Mod  O3 Mod` / `TMRW  PM2.5 Mod  O3 Mod` |
| **Advisory** (only if `actionDay`) | ~6 s | Red bar, `OZONE ACTION DAY`, county scope marquee |

Animation runs once per Tidbyt rotation, then the device cycles to the next app. This is friendlier for "ambient awareness" because each pane is uncrowded; it's heavier on render budget.

## Color reference

All colors used by the app, named so they're easier to talk about.

### EPA AQI category colors (`AQI_BG` in main.star)

These match AirNow / EPA's standard palette. Don't fetch them from any API — hard-code so the device works offline.

| AQI | Category | Color name | Hex | Foreground (`AQI_FG`) |
| --- | --- | --- | --- | --- |
| 0–50 | Good | **EPA green** | `#00E400` | black |
| 51–100 | Moderate | **EPA yellow** | `#FFFF00` | black |
| 101–150 | Unhealthy for Sensitive Groups (USG) | **EPA orange** | `#FF7E00` | black |
| 151–200 | Unhealthy | **EPA red** | `#FF0000` | white |
| 201–300 | Very Unhealthy | **EPA purple** | `#8F3F97` | white |
| 301–500 | Hazardous | **EPA maroon** | `#7E0023` | white |

The foreground (text/number) flips black↔white at AQI 151 (red) to keep contrast high. Tidbyt's LED matrix has narrow gamut on the yellow/orange transition — in person "Moderate" can read slightly greenish under bright ambient light.

### Fire icon (smoke alert badge)

Six-color vertical gradient making a stylized 5×7 flame in the big tile's top-right corner.

| Position | Color name | Hex |
| --- | --- | --- |
| Tip (top) | **flame yellow** | `#FFEE00` |
| Upper body | **flame light orange** | `#FFAA00` |
| Mid body | **flame orange** | `#FF7700` |
| Lower body | **flame red-orange** | `#FF4400` |
| Core | **flame red** | `#FF1100` |
| Base | **flame dark red** | `#AA0000` |

### UI accents

| Use | Color name | Hex |
| --- | --- | --- |
| Pollutant labels (right column) | **white** | `#FFFFFF` |
| Weekday labels (forecast row) | **dim grey** | `#AAAAAA` |
| Missing-forecast outline (hollow square) | **dim grey** (`NO_DATA_EDGE`) | `#AAAAAA` |
| Action Day badge background | (reuses **EPA orange**) | `#FF7E00` |
| Tile background fallback (unknown category) | **fallback grey** | `#444444` |

### LED matrix color caveat

Tidbyt's RGB matrix has visible **channel imbalance at low PWM levels** — when all three channels are driven to roughly equal mid-low values, the red phosphor outputs more lumens per unit current than green or blue, and the result reads as a pinkish-red instead of a neutral grey. This bit-depth-adjacent behavior caught us on the 2026-06-21 photos when a missing-forecast dot was filled with `#666666` and looked like a dim category color rather than a clear "no data" cue.

Lessons:

- **Don't use dim balanced greys (`#444`–`#888`) for filled shapes** that need to read as "neutral/no-data."
- **An outline reads better than a fill** for the no-data state — the white edge against black interior is unambiguous and doesn't compete with the saturated AQI colors.
- **EPA's primary palette colors render reliably** — they sit at gamut extremes (full red, full green, full red+green for yellow, etc.) where PWM imbalance isn't visible.

## Caching strategy

The device polls Tidbyt's render service every few minutes. LUR updates every ~5 min; AirNow data is hourly. Aim for at most ~12 upstream hits/hour total:

| Call | TTL | Rationale |
| --- | --- | --- |
| `LUR_pm_stats.json` | `300` (5 min) | Matches BoulderAIR's update cadence. |
| `LUR_o3_stats.json` | `300` | Same cadence. |
| `LUR_met_stats.json` (for NO2) | `300` | Same cadence. |
| AirNow `/aq/forecast/latLong/` | `1800` (30 min) | Forecast updates 1–2×/day. |
| AirNow `/aq/observation/latLong/current/` (fallback only) | `900` (15 min) | Only fetched if LUR is stale; longer TTL since it's the backup. |
| (v2) Open-Meteo CAMS | `1800` | Hourly underlying. |

Use a single cache key per URL so the device's frequent re-renders don't multiply outbound calls.

## Starlark sketch

A working skeleton — LUR-primary, AirNow forecast, fallback to AirNow obs if LUR is stale.

```python
load("render.star", "render")
load("http.star", "http")
load("encoding/json.star", "json")
load("schema.star", "schema")
load("time.star", "time")

LAT, LNG = 40.147796, -105.088271  # 766 S Martin St
LUR_BASE = "https://www.bouldair.com/webdata/LUR/json"
AIRNOW   = "https://www.airnowapi.org"

AQI_COLORS = {1:"#00E400", 2:"#FFFF00", 3:"#FF7E00", 4:"#FF0000", 5:"#8F3F97", 6:"#7E0023"}
AQI_SHORT  = {1:"Good", 2:"Mod", 3:"USG", 4:"Unh", 5:"VU", 6:"Haz"}

# EPA AQI breakpoints (truncated to the categories we'd realistically display).
PM25_BP = [(0, 12.0, 0, 50, 1), (12.1, 35.4, 51, 100, 2), (35.5, 55.4, 101, 150, 3),
           (55.5, 150.4, 151, 200, 4), (150.5, 250.4, 201, 300, 5), (250.5, 500.4, 301, 500, 6)]
PM10_BP = [(0, 54, 0, 50, 1), (55, 154, 51, 100, 2), (155, 254, 101, 150, 3),
           (255, 354, 151, 200, 4), (355, 424, 201, 300, 5), (425, 604, 301, 500, 6)]
O3_8H_BP = [(0, 54, 0, 50, 1), (55, 70, 51, 100, 2), (71, 85, 101, 150, 3),
            (86, 105, 151, 200, 4), (106, 200, 201, 300, 5)]

def aqi_from_concentration(c, breakpoints):
    for c_lo, c_hi, i_lo, i_hi, cat in breakpoints:
        if c >= c_lo and c <= c_hi:
            return int(round((i_hi - i_lo) * (c - c_lo) / (c_hi - c_lo) + i_lo)), cat
    return None, 0

def fetch_lur(meas):
    # JSONP wrapped JSON. Strip "var X =" and "}" trailer.
    r = http.get("%s/LUR_%s_stats.json" % (LUR_BASE, meas), ttl_seconds=300)
    if r.status_code != 200: return None
    body = r.body()
    return json.decode(body[body.index("{"):body.rindex("}") + 1])

def fetch_forecast(key):
    url = "%s/aq/forecast/latLong/?format=application/json&latitude=%f&longitude=%f&API_KEY=%s" % (AIRNOW, LAT, LNG, key)
    r = http.get(url, ttl_seconds=1800)
    return r.json() if r.status_code == 200 else []

def lur_current(data, field):
    # data["head"] = ["time", field1, field2, ...]; data["curMinMaxAvg"][i] = [cur, min, max, avg]
    if not data: return None
    head = data["head"]
    if field not in head: return None
    idx = head.index(field) - 1  # subtract 1 because "time" has no curMinMaxAvg row
    return data["curMinMaxAvg"][idx][0]

def is_stale(data, max_age_s = 1800):
    if not data: return True
    return (time.now().unix - int(data.get("t9", 0))) > max_age_s

def main(config):
    key = config.get("airnow_api_key", "")
    pm  = fetch_lur("pm")
    o3  = fetch_lur("o3")
    met = fetch_lur("met")  # for NO2

    candidates = []
    if not is_stale(pm):
        pm25 = lur_current(pm, "pm2_5")
        if pm25 != None:
            aqi, cat = aqi_from_concentration(pm25, PM25_BP)
            candidates.append(("PM2.5", aqi, cat))
        pm10 = lur_current(pm, "pm10")
        if pm10 != None:
            aqi, cat = aqi_from_concentration(pm10, PM10_BP)
            candidates.append(("PM10", aqi, cat))
    if not is_stale(o3):
        o3v = lur_current(o3, "o3")
        if o3v != None:
            aqi, cat = aqi_from_concentration(o3v, O3_8H_BP)
            candidates.append(("O3", aqi, cat))

    fcst = fetch_forecast(key)
    action_day = any([f.get("ActionDay") for f in fcst])

    if not candidates:
        # All LUR endpoints stale or down — fall back to AirNow obs at the address.
        return _airnow_fallback(key, fcst, action_day)

    dom = candidates[0]
    for c in candidates[1:]:
        if c[1] > dom[1]: dom = c

    return render.Root(
        delay = 10000,
        child = render.Stack(children = [
            _background(dom[2]),
            render.Column(children = [
                _header(action_day, "LUR"),
                render.Row(expanded = True, children = [
                    _big_tile(dom[1], dom[0]),
                    _right_col(candidates, fcst),
                ]),
            ]),
        ]),
    )

# … _header, _big_tile, _right_col, _background, _airnow_fallback helpers …
```

The skeleton runs locally with `pixlet serve main.star --config airnow_api_key=…`; pushed to a device with `pixlet push longmont-aq.webp $DEVICE_ID --installation-id longmont-aq`.

Notes on the AQI math:

- The O3 breakpoints above are the 8-hour-O3 NAAQS table. BoulderAIR's `curMinMaxAvg` "current" is a 5-min spot read, not an 8-hour rolling average. For a quick-glance display this is fine, but for an accurate AQI you'd compute the 8-hr rolling from `LUR_o3_3day.json`. v2 enhancement.
- Same caveat for PM2.5: the EPA AQI is from the 24-hr NowCast, not the spot read. Spot read for ambient awareness is reasonable; document the choice in the device tooltip.

## Open questions to resolve before shipping

- ~~**BoulderAIR feed.**~~ **Resolved 2026-06-21.** Per-site JSONP at `bouldair.com/webdata/<SITE>/json/`. See the endpoint catalog above and the BoulderAIR subsection in [research-notes.md](../research-notes.md). LUR is the primary source for this app.
- **Does LNGM (080130003) actually report ozone, or only PM10/PM2.5?** With LUR now primary for current obs, this is no longer blocking — but still useful for the LNGM cross-check feature. Confirm by curl'ing `/aq/data/?` with the LNGM bbox and `parameters=OZONE`.
- **Confirm AirNow `/aq/data/?` returns LNGM in a real query.** Needed only for the LNGM cross-check. Try it before the v1.1 feature that adds the "what does the regulatory monitor say" line.
- ~~**Rolling-average AQI.**~~ **Partially resolved 2026-06-21.** O3 now uses the 8-hr rolling mean of `LUR_o3_3day.json` instead of the 5-min spot value, since the EPA 8-hr breakpoints expect that (spot values inflated AQI by ~20-30 points on a typical afternoon — first photo showed AQI 91 from 67 ppb spot, where the 8-hr mean and AirNow's "Moderate" forecast both implied ~70s). PM2.5 is still using the spot value against the 24-hr breakpoints — concentrations don't swing as dramatically intra-day, so the error is small (~3-5 AQI points), but a proper EPA NowCast would be more honest. Defer until smoke season tests it.
- **Tomorrow's CAMS spike.** Today's research showed CAMS predicting an ozone AQI 96 for tomorrow vs. CDPHE saying flat Moderate. If the spike materializes, the Action Day field on AirNow's forecast will flip and the advisory frame should render automatically — worth eyeball-testing this code path before relying on it.
- **LUR uptime / staleness.** BoulderAIR is research-grade but not enterprise SLA. The `is_stale` check above falls back to AirNow if `t9` is more than 30 min old. Watch the first few weeks of running to see how often that triggers.

## Stretch ideas (v2+)

- **Sparkline of the last 3 days** at the bottom of Layout A using `render.Plot`. Pull from `LUR_<meas>_3day.json` — no extra API needed.
- **Methane plume alert.** LUR's CH4 right now is 2040 ppb vs. ~1900 ppb background. A persistent CH4 elevation (>2200 for >1 hour) likely indicates an oil-and-gas plume; light a small flame icon. Pure BoulderAIR feature; AirNow / CAMS can't do this.
- **Benzene alert.** LUR_voc carries benzene. Health-relevant for oil-and-gas exposure. Light an alert above a threshold (e.g., 1 ppb).
- **CAMS overlay on the forecast frame** showing CDPHE category vs. CAMS-predicted peak AQI side by side. Lets you see when the model disagrees with the human forecaster (today's worked example would have flagged tomorrow's ozone).
- **PM2.5 NowCast.** v1.1 added the 8-hr O3 rolling; PM2.5 still uses the spot value. EPA's NowCast is a 12-hour weighted average that's responsive to spikes. Implement when smoke season starts so high-PM events read more honestly.
- **LNGM cross-check line.** A small text row "LNGM PM2.5 = 9.5" so you can sanity-check LUR against the closest regulatory monitor at 350 Kimbark St.
- **PurpleAir nearest-neighbor read** as a hyperlocal cross-check on PM2.5, applying the EPA Barkjohn correction inline. Requires the PurpleAir read key (manual email request).
- **Wildfire smoke mode** triggered by HRRR-Smoke or HMS satellite product — show a fire icon and a smoke-specific AQI when PM2.5 > 25 µg/m³ for 3+ hours.
