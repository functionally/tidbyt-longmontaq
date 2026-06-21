"""Longmont air-quality — Pixlet/Tidbyt app for 766 S Martin St.

Primary source: BoulderAIR LUR (Longmont Union Reservoir, ~6 km NE)
  https://www.bouldair.com/webdata/LUR/json/LUR_<meas>_(stats|3day).json
Secondary: AirNow forecast (CDPHE-issued) for today/tomorrow categories.
Fallback: AirNow current observations within 25 mi (if LUR is stale).

Smoke indicator: PM2.5 3-hr rolling mean from LUR_pm_3day > 25 µg/m³ lights
the SMK badge and forces PM2.5 into the big tile.

See ./design-notes.md for the full design rationale.
"""

load("render.star", "render")
load("http.star", "http")
load("encoding/json.star", "json")
load("schema.star", "schema")
load("time.star", "time")

LAT = 40.147796
LNG = -105.088271

LUR_BASE = "https://www.bouldair.com/webdata/LUR/json"
AIRNOW = "https://www.airnowapi.org"

SMOKE_PM25_UGM3 = 25.0
SMOKE_WINDOW_S = 3 * 3600
STALE_S = 1800

# Plausibility bounds — values outside these ranges are treated as sensor
# glitches and dropped from rolling means. Real outdoor O3 maxes around
# 150 ppb during extreme events; PM2.5 maxes around 500 µg/m³ in wildfire
# smoke; PM10 around 600 µg/m³ in dust events. These bounds are sized to
# admit even those extremes while rejecting clear sensor errors (negative
# values, 9999 sentinels, half-written JSON).
SANE_O3_PPB = (0, 200)
SANE_PM25_UGM3 = (0, 500)
SANE_PM10_UGM3 = (0, 800)

# EPA AQI breakpoints. (conc_lo, conc_hi, aqi_lo, aqi_hi, category)
PM25_BP = [
    (0.0, 12.0, 0, 50, 1),
    (12.1, 35.4, 51, 100, 2),
    (35.5, 55.4, 101, 150, 3),
    (55.5, 150.4, 151, 200, 4),
    (150.5, 250.4, 201, 300, 5),
    (250.5, 500.4, 301, 500, 6),
]
PM10_BP = [
    (0, 54, 0, 50, 1),
    (55, 154, 51, 100, 2),
    (155, 254, 101, 150, 3),
    (255, 354, 151, 200, 4),
    (355, 424, 201, 300, 5),
    (425, 604, 301, 500, 6),
]

# 8-hour ozone (ppb) breakpoints.
O3_8H_BP = [
    (0, 54, 0, 50, 1),
    (55, 70, 51, 100, 2),
    (71, 85, 101, 150, 3),
    (86, 105, 151, 200, 4),
    (106, 200, 201, 300, 5),
]

AQI_BG = {1: "#00E400", 2: "#FFFF00", 3: "#FF7E00", 4: "#FF0000", 5: "#8F3F97", 6: "#7E0023"}
AQI_FG = {1: "#000000", 2: "#000000", 3: "#000000", 4: "#FFFFFF", 5: "#FFFFFF", 6: "#FFFFFF"}
# Outline color for the "no forecast data" hollow square. Avoid dim grey
# (#444-#888 range) because the Tidbyt LED matrix has visible channel
# imbalance at low PWM levels and renders dim balanced grey as pinkish-red.
NO_DATA_EDGE = "#AAAAAA"
CAT_FROM_NAME = {
    "Good": 1,
    "Moderate": 2,
    "Unhealthy for Sensitive Groups": 3,
    "Unhealthy": 4,
    "Very Unhealthy": 5,
    "Hazardous": 6,
}

def _round_half_up(x):
    if x >= 0:
        return int(x + 0.5)
    return -int(-x + 0.5)

def aqi_from_concentration(c, breakpoints):
    if c == None:
        return None, 0
    for bp in breakpoints:
        c_lo, c_hi, i_lo, i_hi, cat = bp[0], bp[1], bp[2], bp[3], bp[4]
        if c >= c_lo and c <= c_hi:
            aqi = _round_half_up((i_hi - i_lo) * (c - c_lo) / (c_hi - c_lo) + i_lo)
            return aqi, cat
    top = breakpoints[-1]
    return top[3], top[4]

def _strip_jsonp(body):
    s = body.find("{")
    e = body.rfind("}") + 1
    if s < 0 or e <= s:
        return None
    return json.decode(body[s:e])

def fetch_lur_3day(meas, ttl = 300):
    r = http.get("%s/LUR_%s_3day.json" % (LUR_BASE, meas), ttl_seconds = ttl)
    if r.status_code != 200:
        return None
    return _strip_jsonp(r.body())

def fetch_airnow_forecast(key):
    if not key:
        return []
    url = "%s/aq/forecast/latLong/?format=application/json&latitude=%f&longitude=%f&API_KEY=%s" % (AIRNOW, LAT, LNG, key)
    r = http.get(url, ttl_seconds = 1800)
    if r.status_code != 200:
        return []
    return r.json() or []

def fetch_airnow_obs(key):
    if not key:
        return []
    url = "%s/aq/observation/latLong/current/?format=application/json&latitude=%f&longitude=%f&distance=25&API_KEY=%s" % (AIRNOW, LAT, LNG, key)
    r = http.get(url, ttl_seconds = 900)
    if r.status_code != 200:
        return []
    return r.json() or []

def _in_range(v, bounds):
    """True if v is a numeric value within (inclusive) bounds. Used to drop
    sensor glitches and parser garbage from rolling means."""
    if v == None:
        return False
    return v >= bounds[0] and v <= bounds[1]

def lur_3day_latest(d3, field, bounds = None):
    """Latest sample for `field`. If `bounds` is provided, walk backwards
    until we find an in-range sample (rather than blindly trusting the last
    row, which might be the half-written sample that started this whole
    mess)."""
    if d3 == None:
        return None, 0
    head = d3.get("head", [])
    if field not in head:
        return None, 0
    col = head.index(field)
    rows = d3.get("data", [])
    if len(rows) == 0:
        return None, 0
    if bounds == None:
        last = rows[-1]
        return last[col], int(last[0])
    for i in range(len(rows) - 1, -1, -1):
        v = rows[i][col]
        if _in_range(v, bounds):
            return v, int(rows[i][0])
    return None, 0

def _rolling_mean(d3, field, window_s, bounds):
    """Arithmetic mean of `field` over the last `window_s` seconds, dropping
    any sample outside `bounds`. Returns None if no in-range samples land in
    the window."""
    if d3 == None:
        return None
    head = d3.get("head", [])
    if field not in head:
        return None
    col = head.index(field)
    cutoff = time.now().unix - window_s
    total = 0.0
    n = 0
    for row in d3.get("data", []):
        if row[0] >= cutoff and _in_range(row[col], bounds):
            total += row[col]
            n += 1
    if n == 0:
        return None
    return total / n

def pm25_3h_mean(d3):
    return _rolling_mean(d3, "pm2_5", SMOKE_WINDOW_S, SANE_PM25_UGM3)

def o3_8hr_mean(d3):
    """8-hour rolling mean of O3, sanity-bounded. EPA's 8-hour O3 breakpoints
    expect a true 8-hour mean — feeding spot reads inflates AQI by ~20-30
    points on a typical afternoon. The bounds guard against single glitched
    samples poisoning the mean (one 9999 sentinel can push a moderate
    afternoon all the way to AQI 300, which is what triggered this code path
    in the first place)."""
    return _rolling_mean(d3, "o3", 8 * 3600, SANE_O3_PPB)

def _is_stale(epoch):
    if not epoch:
        return True
    return (time.now().unix - int(epoch)) > STALE_S

def _pick(f, names):
    """Look up the first non-empty value among `names` in dict `f`.
    AirNow's response is documented as PascalCase (DateForecast, CategoryName,
    etc.) but some variant endpoints have shipped camelCase; check both."""
    for n in names:
        v = f.get(n)
        if v != None and v != "":
            return v
    return None

def _forecast_cats(forecast):
    """Worst category number per date for today and tomorrow."""
    if len(forecast) == 0:
        return 0, 0
    by_date = {}
    for f in forecast:
        d = _pick(f, ["DateForecast", "DateValid", "dateForecast", "dateValid"]) or ""
        cat_name = _pick(f, ["CategoryName", "categoryName"])
        if cat_name == None:
            cat_obj = f.get("Category") or f.get("category") or {}
            cat_name = cat_obj.get("Name") or cat_obj.get("name", "")
        cat_num = CAT_FROM_NAME.get(cat_name, 0)
        if d not in by_date or cat_num > by_date[d]:
            by_date[d] = cat_num
    dates = sorted(by_date.keys())
    today = by_date[dates[0]] if len(dates) >= 1 else 0
    tmrw = by_date[dates[1]] if len(dates) >= 2 else 0
    return today, tmrw

def _two_char_weekday(t):
    """Two-letter weekday abbreviation for a Time, e.g., 'Su', 'Mo', 'Tu'.
    Cleaner than 'T'/'M' since each abbreviation is unambiguous on its own."""
    return t.format("Mon")[:2]

def _action_day(forecast):
    for f in forecast:
        if f.get("ActionDay") or f.get("actionDay"):
            return True
    return False

def _badge(text, color):
    return render.Box(
        width = 14,
        height = 7,
        color = color,
        child = render.Padding(
            pad = (1, 1, 0, 0),
            child = render.Text(text, color = "#FFFFFF", font = "tom-thumb"),
        ),
    )

def _fire_icon():
    """Stylized pixel flame for the smoke badge. 5 px wide × 7 px tall.

       ..Y..
       .YOO.
       .OOO.
       OOROO
       ORRRO
       ORRRO
       .RRR.
    """
    return render.Column(
        cross_align = "center",
        children = [
            render.Box(width = 1, height = 1, color = "#FFEE00"),
            render.Box(width = 3, height = 1, color = "#FFAA00"),
            render.Box(width = 3, height = 1, color = "#FF7700"),
            render.Box(width = 5, height = 1, color = "#FF4400"),
            render.Box(width = 5, height = 2, color = "#FF1100"),
            render.Box(width = 3, height = 1, color = "#AA0000"),
        ],
    )

def _alert_badge(smoke, action_day):
    if smoke:
        return _fire_icon()
    if action_day:
        return _badge("ACT", "#FF7E00")
    return None

def _big_tile(dom, smoke, action_day):
    """Left tile: 28x32. Big AQI number centered (color-coded category
    background). When an alert is active, a small badge sits in the top-right
    corner. No pollutant label — the right column lets you match the number to
    a pollutant when needed."""
    _label, aqi, cat = dom[0], dom[1], dom[2]
    bg = AQI_BG.get(cat, "#444444")
    fg = AQI_FG.get(cat, "#FFFFFF")

    # 10x20 looks great at 2 digits; 6x13 takes over at 3+ so 100+ doesn't
    # clip in a 28 px tile. The size discontinuity at AQI=100 is intentional
    # — it's a category boundary anyway.
    aqi_str = str(aqi)
    big_font = "10x20" if len(aqi_str) <= 2 else "6x13"
    number = render.Text(aqi_str, color = fg, font = big_font)

    badge = _alert_badge(smoke, action_day)

    if badge == None:
        body = render.Column(
            expanded = True,
            main_align = "center",
            cross_align = "center",
            children = [number],
        )
    else:
        body = render.Column(
            expanded = True,
            main_align = "space_between",
            cross_align = "center",
            children = [
                render.Row(
                    expanded = True,
                    main_align = "end",
                    children = [render.Padding(pad = (0, 1, 1, 0), child = badge)],
                ),
                render.Padding(pad = (0, 0, 0, 3), child = number),
            ],
        )

    return render.Box(width = 28, height = 32, color = bg, child = body)

def _pollutant_row(label, aqi, cat):
    """Right-column row: pollutant label on the left, AQI number color-coded
    by category on the right, empty space between. Color is the only
    category cue — accessibility note for color-blind users in design-notes."""
    color = AQI_BG.get(cat, "#FFFFFF")
    return render.Row(
        expanded = True,
        main_align = "space_between",
        children = [
            render.Text(label, color = "#FFFFFF", font = "tom-thumb"),
            render.Text(str(aqi), color = color, font = "tom-thumb"),
        ],
    )

def _forecast_square(cat):
    """4×4 colored square for one day in the forecast row. When we have a
    real category (1–6) we fill it with the AQI background color. When we
    don't (cat = 0, missing data), we draw a hollow 4×4 outline using small
    dim-white edge boxes instead — Tidbyt's LED matrix renders dim balanced
    grey poorly (channel imbalance at low PWM makes #666 look pinkish), so
    an outline reads as 'no data' more reliably than a grey fill."""
    if cat > 0:
        return render.Box(width = 4, height = 4, color = AQI_BG.get(cat, "#444444"))
    # Hollow 4×4: top + bottom edge (1px), with left+right column hugging the
    # middle two rows.
    return render.Column(children = [
        render.Box(width = 4, height = 1, color = NO_DATA_EDGE),
        render.Row(children = [
            render.Box(width = 1, height = 2, color = NO_DATA_EDGE),
            render.Box(width = 2, height = 2, color = "#000000"),
            render.Box(width = 1, height = 2, color = NO_DATA_EDGE),
        ]),
        render.Box(width = 4, height = 1, color = NO_DATA_EDGE),
    ])

def _forecast_dots_row(forecast):
    """Bottom row of the right column: Su▮ Mo▮ where each label is the
    actual two-letter weekday and each square is colored by that day's
    AirNow forecast category. Self-explanatory (no key needed)."""
    tdy_cat, tmr_cat = _forecast_cats(forecast)

    today = time.now().in_location("America/Denver")
    tomorrow = time.from_timestamp(today.unix + 86400).in_location("America/Denver")
    tdy_label = _two_char_weekday(today)
    tmr_label = _two_char_weekday(tomorrow)

    return render.Row(
        expanded = True,
        main_align = "space_around",
        cross_align = "center",
        children = [
            render.Row(
                cross_align = "center",
                children = [
                    render.Text(tdy_label, color = "#AAAAAA", font = "tom-thumb"),
                    render.Padding(pad = (1, 0, 0, 0), child = _forecast_square(tdy_cat)),
                ],
            ),
            render.Row(
                cross_align = "center",
                children = [
                    render.Text(tmr_label, color = "#AAAAAA", font = "tom-thumb"),
                    render.Padding(pad = (1, 0, 0, 0), child = _forecast_square(tmr_cat)),
                ],
            ),
        ],
    )

def _right_col(rows, forecast):
    children = []
    for r in rows:
        children.append(_pollutant_row(r[0], r[1], r[2]))
    children.append(_forecast_dots_row(forecast))
    return render.Padding(
        pad = (2, 0, 0, 0),
        child = render.Column(
            expanded = True,
            main_align = "space_evenly",
            children = children,
        ),
    )

def _airnow_fallback_view(key, forecast, action_day):
    obs = fetch_airnow_obs(key)
    rows = []
    for o in obs:
        p = o.get("ParameterName", "")
        aqi = o.get("AQI", -1)
        cat_obj = o.get("Category", {})
        cat = cat_obj.get("Number", 0) if cat_obj else 0
        if aqi >= 0 and cat > 0:
            label = "PM2.5" if p == "PM2.5" else (p if len(p) <= 5 else p[:5])
            rows.append((label, aqi, cat))
    if len(rows) == 0:
        return render.Box(
            color = "#222222",
            child = render.Text("AQ N/A", color = "#FFFFFF", font = "tb-8"),
        )
    dom = rows[0]
    for r in rows[1:]:
        if r[1] > dom[1]:
            dom = r
    return render.Row(
        expanded = True,
        main_align = "space_between",
        children = [_big_tile(dom, False, action_day), _right_col(rows, forecast)],
    )

def main(config):
    airnow_key = config.get("airnow_api_key", "")

    pm_3day = fetch_lur_3day("pm")
    o3_3day = fetch_lur_3day("o3")

    pm25, _ = lur_3day_latest(pm_3day, "pm2_5", SANE_PM25_UGM3)
    pm10, _ = lur_3day_latest(pm_3day, "pm10", SANE_PM10_UGM3)

    # O3 AQI is based on the 8-hour rolling mean per EPA's spec — that's what
    # the O3_8H_BP breakpoints are calibrated against. Using a 5-min spot
    # value here would inflate the AQI by 20+ points on a typical afternoon.
    o3_8hr = o3_8hr_mean(o3_3day)
    _o3_latest, o3_ts = lur_3day_latest(o3_3day, "o3", SANE_O3_PPB)
    o3_for_aqi = o3_8hr if not _is_stale(o3_ts) else None

    pm25_3h = pm25_3h_mean(pm_3day)
    smoke = pm25_3h != None and pm25_3h > SMOKE_PM25_UGM3

    rows = []
    if pm25 != None:
        aqi, cat = aqi_from_concentration(pm25, PM25_BP)
        if aqi != None:
            rows.append(("PM2.5", aqi, cat, pm25))
    if pm10 != None:
        aqi, cat = aqi_from_concentration(pm10, PM10_BP)
        if aqi != None:
            rows.append(("PM10", aqi, cat, pm10))
    if o3_for_aqi != None:
        aqi, cat = aqi_from_concentration(o3_for_aqi, O3_8H_BP)
        if aqi != None:
            rows.append(("O3", aqi, cat, o3_for_aqi))

    forecast = fetch_airnow_forecast(airnow_key)
    action_day = _action_day(forecast)

    if len(rows) == 0:
        return render.Root(
            delay = 10000,
            child = _airnow_fallback_view(airnow_key, forecast, action_day),
        )

    if smoke:
        dom = None
        for r in rows:
            if r[0] == "PM2.5":
                dom = r
                break
        if dom == None:
            dom = rows[0]
    else:
        dom = rows[0]
        for r in rows[1:]:
            if r[1] > dom[1]:
                dom = r

    return render.Root(
        delay = 10000,
        child = render.Row(
            expanded = True,
            main_align = "space_between",
            children = [
                _big_tile((dom[0], dom[1], dom[2]), smoke, action_day),
                _right_col([(r[0], r[1], r[2]) for r in rows], forecast),
            ],
        ),
    )

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(
                id = "airnow_api_key",
                name = "AirNow API key",
                desc = "Free key from airnowapi.org. Used for the daily forecast and the obs fallback.",
                icon = "key",
            ),
        ],
    )
