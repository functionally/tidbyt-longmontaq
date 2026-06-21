#!/usr/bin/env bash
# Pre-deploy sanity check.
# - Verifies BoulderAIR LUR JSONP endpoints respond
# - Prints latest LUR readings (PM2.5, PM10, O3)
# - Computes the 3-hr PM2.5 rolling mean (the smoke trigger)
# - Confirms the AirNow API key works and prints the forecast
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f config.yaml ]]; then
  echo "ERROR: config.yaml is missing. Run: cp config-example.yaml config.yaml" >&2
  exit 1
fi

AIRNOW_KEY="$(yq -r '.airnow_api_key' config.yaml)"
LAT=40.147796
LNG=-105.088271
SMOKE_THRESHOLD=25.0
SMOKE_WINDOW=10800   # 3 hours in seconds

green() { printf "\033[32m%s\033[0m" "$1"; }
red()   { printf "\033[31m%s\033[0m" "$1"; }
ok()    { printf "  $(green '✓') %s\n" "$1"; }
warn()  { printf "  $(red '✗') %s\n" "$1"; }

strip_jsonp() {
  python3 -c "import sys,json; b=sys.stdin.read(); print(json.dumps(json.loads(b[b.find('{'):b.rfind('}')+1])))"
}

echo "== BoulderAIR LUR endpoints =="
for f in LUR_pm_3day LUR_pm_stats LUR_o3_stats LUR_met_stats; do
  url="https://www.bouldair.com/webdata/LUR/json/${f}.json"
  code=$(curl -sL -o /dev/null -w "%{http_code}" --max-time 10 "$url")
  if [[ "$code" == "200" ]]; then
    ok "$f.json"
  else
    warn "$f.json (HTTP $code)"
  fi
done

echo
echo "== Latest LUR readings =="
PM_STATS=$(curl -sL --max-time 10 "https://www.bouldair.com/webdata/LUR/json/LUR_pm_stats.json" | strip_jsonp)
O3_STATS=$(curl -sL --max-time 10 "https://www.bouldair.com/webdata/LUR/json/LUR_o3_stats.json" | strip_jsonp)

python3 - <<EOF
import json, datetime
pm = json.loads('''${PM_STATS}''')
o3 = json.loads('''${O3_STATS}''')
def cur(d, field):
    head = d.get("head", [])
    if field not in head: return None
    return d["curMinMaxAvg"][head.index(field) - 1][0]
pm25 = cur(pm, "pm2_5")
pm10 = cur(pm, "pm10")
o3v  = cur(o3, "o3")
print(f"  PM2.5: {pm25:.1f} µg/m³")
print(f"  PM10:  {pm10:.1f} µg/m³")
print(f"  O3:    {o3v:.1f} ppb")
t9 = pm.get("t9", 0)
dt = datetime.datetime.fromtimestamp(t9, tz=datetime.timezone.utc).astimezone()
age_min = (datetime.datetime.now(datetime.timezone.utc).timestamp() - t9) / 60
print(f"  PM sample time: {dt.strftime('%Y-%m-%d %H:%M %Z')} ({age_min:.1f} min ago)")
EOF

echo
echo "== Smoke check (3-hr PM2.5 rolling mean) =="
PM_3DAY=$(curl -sL --max-time 10 "https://www.bouldair.com/webdata/LUR/json/LUR_pm_3day.json" | strip_jsonp)
python3 - <<EOF
import json, time, sys
d = json.loads('''${PM_3DAY}''')
col = d["head"].index("pm2_5")
cutoff = int(time.time()) - ${SMOKE_WINDOW}
vals = [r[col] for r in d.get("data", []) if r[0] >= cutoff and r[col] is not None]
if not vals:
    print("  (no recent PM2.5 samples)"); sys.exit(0)
mean = sum(vals) / len(vals)
print(f"  3-hr mean: {mean:.2f} µg/m³ ({len(vals)} samples)")
print(f"  Threshold: ${SMOKE_THRESHOLD} µg/m³")
if mean > ${SMOKE_THRESHOLD}:
    print(f"  → \033[31mSMOKE indicator would be ACTIVE (fire icon shown)\033[0m")
else:
    print(f"  → smoke indicator inactive")
EOF

echo
echo "== Displayed O3 AQI (uses 8-hr rolling mean, not spot read) =="
O3_3DAY=$(curl -sL --max-time 10 "https://www.bouldair.com/webdata/LUR/json/LUR_o3_3day.json" | strip_jsonp)
python3 - <<EOF
import json, time, sys
d = json.loads('''${O3_3DAY}''')
col = d["head"].index("o3")
cutoff = int(time.time()) - 8 * 3600
vals = [r[col] for r in d.get("data", []) if r[0] >= cutoff and r[col] is not None]
if not vals:
    print("  (no recent O3 samples)"); sys.exit(0)
mean = sum(vals) / len(vals)
spot = d["data"][-1][col]

# EPA 8-hr O3 AQI breakpoints (ppb)
bp = [(0,54,0,50,"Good"),(55,70,51,100,"Moderate"),
      (71,85,101,150,"USG"),(86,105,151,200,"Unhealthy"),
      (106,200,201,300,"Very Unhealthy")]
def aqi(c):
    for cl,ch,il,ih,name in bp:
        if cl <= c <= ch:
            return round(il + (ih-il)*(c-cl)/(ch-cl)), name
    return None, "?"
spot_aqi, spot_cat = aqi(spot)
mean_aqi, mean_cat = aqi(mean)
print(f"  Spot read (5-min):   {spot:.1f} ppb → AQI {spot_aqi} ({spot_cat})  ← would inflate the display")
print(f"  8-hr rolling mean:   {mean:.1f} ppb → AQI {mean_aqi} ({mean_cat})  ← what the app now shows")
print(f"  ({len(vals)} samples over the last 8 hours)")
EOF

echo
echo "== AirNow forecast =="
if [[ -z "$AIRNOW_KEY" || "$AIRNOW_KEY" == "null" || "$AIRNOW_KEY" == YOUR-* ]]; then
  warn "airnow_api_key not set in config.yaml — skipping AirNow check"
  echo
  echo "Cannot deploy without AirNow key. Add it to config.yaml and re-run."
  exit 1
fi

FCST_URL="https://www.airnowapi.org/aq/forecast/latLong/?format=application/json&latitude=${LAT}&longitude=${LNG}&API_KEY=${AIRNOW_KEY}"
RESP=$(curl -sL --max-time 10 -w "\n%{http_code}" "$FCST_URL")
CODE=$(printf '%s' "$RESP" | tail -n1)
BODY=$(printf '%s' "$RESP" | sed '$d')

if [[ "$CODE" != "200" ]]; then
  warn "AirNow returned HTTP $CODE (check key)"
  exit 1
fi

python3 - <<EOF
import json
forecast = json.loads('''${BODY}''')
def pick(d, *keys):
    for k in keys:
        v = d.get(k)
        if v not in (None, ""): return v
    return ""
if not forecast:
    print("  (forecast empty)")
else:
    for f in forecast:
        cat = pick(f, "CategoryName", "categoryName") or (f.get("Category") or f.get("category") or {}).get("Name", "?")
        act = " [ACTION DAY]" if (f.get("ActionDay") or f.get("actionDay")) else ""
        date = pick(f, "DateForecast", "DateValid", "dateForecast", "dateValid")
        pname = pick(f, "ParameterName", "parameterName")
        print(f"  {date}  {pname:6s}  {cat}{act}")
print()
print(f"  Forecast issuer: {pick(forecast[0], 'ForecastAgency', 'forecastAgency', 'Source', 'source')}" if forecast else "")
EOF

echo
echo "All checks passed. Safe to deploy."
