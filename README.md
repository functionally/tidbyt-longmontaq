# Longmont air-quality Tidbyt app

A Pixlet app for the Tidbyt that displays current PM2.5 / PM10 / O3 plus today/tomorrow forecast at 766 S Martin St, Longmont, CO. Primary source: **BoulderAIR LUR** (Longmont Union Reservoir, ~6 km NE). Secondary: AirNow forecast (CDPHE-issued). Includes a smoke indicator (3-hr PM2.5 rolling mean).

See [design-notes.md](./design-notes.md) for the full design rationale and source comparison.

## Setup

1. **Enter the dev shell.** This flake provides `pixlet`, `yq-go`, `jq`, `python3`, and `curl`. **The dev shell changed — re-enter it after pulling these files** so the new tools are on `$PATH`:
   ```
   nix develop
   ```

2. **Create config.yaml** from the template and fill in your keys:
   ```
   cp config.yaml.example config.yaml
   ${EDITOR:-vi} config.yaml
   ```

   You need: an [AirNow API key](https://docs.airnowapi.org/) (free), a Tidbyt API token (from `pixlet auth` or your account), and your device ID (`pixlet devices`).

   **Installation ID gotcha:** Tidbyt's API requires the installation ID to be alphanumeric only (no hyphens, underscores, or other punctuation). The example uses `longmontaq` — anything matching `[A-Za-z0-9]+` is fine. `deploy.sh` validates this before pushing.

3. **Sanity-check upstream sources** before deploying:
   ```
   ./scripts/check.sh
   ```
   This verifies the LUR JSONP feed responds, prints today's readings, computes the 3-hr smoke check, and confirms your AirNow key works.

4. **Preview locally** in a browser at <http://localhost:8080>:
   ```
   ./scripts/preview.sh
   ```

5. **One-shot push to the device** (test that everything works end-to-end):
   ```
   ./scripts/deploy.sh
   ```

6. **For continuous push** (a daemon that re-renders every 10 min so the AQI on the device stays current), build and run a podman container. Two ways:

   **Ad-hoc with `podman run`** (matches the older flow):
   ```
   ./scripts/build-container.sh
   ./scripts/run-container.sh                 # foreground; Ctrl-C to stop
   ./scripts/run-container.sh --detach        # background with --restart=always
   ./scripts/run-container.sh --once          # one-shot push for smoke-testing the image
   ```

   **Declarative with `podman kube`** (recommended for long-running):
   ```
   ./scripts/build-container.sh
   podman kube play --replace longmontaq.yaml  # start (or restart with new image)
   podman logs -f longmontaq-aq                # follow the loop log
   podman kube down longmontaq.yaml            # stop
   ```

   The container bakes your `config.yaml` in at build time (no volume mounts needed); rebuilding it picks up edits. See "Container" below for the details.

## Files

| | |
| --- | --- |
| `main.star` | The Pixlet app (Starlark). Layout A — single composite frame. |
| `flake.nix` | Nix dev shell + pixlet derivation + container image. |
| `config.yaml.example` | Template. Copy to `config.yaml` (gitignored). |
| `scripts/check.sh` | Pre-deploy sanity check of upstream sources. |
| `scripts/preview.sh` | `pixlet serve` for browser preview. |
| `scripts/render.sh` | Render one frame to `out.webp`. |
| `scripts/deploy.sh` | Render and `pixlet push` once. |
| `scripts/build-container.sh` | Build the OCI image with credentials baked in; load into podman. |
| `scripts/run-container.sh` | Run the push-daemon container with `podman run` (ad-hoc). |
| `longmontaq.yaml` | Podman kube spec for the push-daemon pod (declarative; recommended). |
| `design-notes.md` | Design rationale, source comparison, open questions. |

## Container

The container is a single-image push daemon: it boots, reads `/app/config.yaml`, then loops `pixlet render → pixlet push → sleep $PUSH_INTERVAL_S` forever. Default cadence is 10 minutes; override with `PUSH_INTERVAL_S=300 ./scripts/run-container.sh`.

What's in it:

- `pixlet` (the same v0.34 binary the dev shell uses).
- `bash`, `coreutils`, `yq-go`, `cacert`, `tzdata` from nixpkgs.
- `/app/main.star`, `/app/config.yaml`, `/app/loop.sh` — copied in at build time.
- Env: `TZ=America/Denver`, `ZONEINFO` pointed at tzdata, `SSL_CERT_FILE` pointed at the Mozilla CA bundle.

How credentials get in: `build-container.sh` exports `LONGMONT_CONFIG_YAML=$(cat config.yaml)` and passes `--impure` to `nix build`. The flake reads that env var via `builtins.getEnv` and `pkgs.writeText`'s it into the image. Side effects:

- The image rebuilds whenever `config.yaml` changes (Nix sees a new derivation hash).
- The credentials end up in the Nix store. On a multi-user system that's a small concern (`/nix/store` is world-readable). On a single-user dev box it's fine.
- No bind mounts needed at run time — the container is self-contained.

How to stop a detached daemon: `podman rm -f longmontaq` (for `run-container.sh`) or `podman kube down longmontaq.yaml` (for the kube flow).

**Autostart on boot:**

- For the kube flow, the simplest path is rootless: `systemctl --user enable --now podman-restart.service` then `podman kube play --replace longmontaq.yaml` once. The restart service brings the pod back up on reboot.
- For tighter systemd integration, convert `longmontaq.yaml` to a Quadlet under `~/.config/containers/systemd/longmontaq.kube` (or `/etc/containers/systemd/` for rootful) and `systemctl --user daemon-reload && systemctl --user enable --now longmontaq-pod.service`.

## Smoke indicator

When the 3-hour rolling mean PM2.5 at LUR exceeds 25 µg/m³, a small pixel-art flame appears in the top-right corner of the big tile, and the big tile is forced to display PM2.5 even if another pollutant happens to have a higher AQI. The threshold is hard-coded in `main.star`; edit `SMOKE_PM25_UGM3` and `SMOKE_WINDOW_S` to tune.

## Display layout

```
┌────────────┐  PM2.5      33
│      [🔥] │  PM10       51
│            │  O3         47
│    51      │
│            │  Su▮  Mo▮
└────────────┘
```

- No header row — the full 32 px height is used for data.
- Left tile (28×32): big AQI number for the dominant pollutant, centered. Background is the EPA category color (green→yellow→orange→red→purple→maroon). When an alert is active (smoke or CDPHE Action Day), a small badge appears in the top-right corner; otherwise the number is centered with no surrounding chrome.
- Right column (34×32): three per-pollutant rows — pollutant name (white) on the left, AQI number (color-coded by category) on the right. The forecast row at the bottom shows two-letter weekday names (`Su`/`Mo`/`Tu`/…) with a small colored square for each day's AirNow forecast category — today on the left, tomorrow on the right.

### Design choices

- **No time/timestamp.** Standard practice for compact AQ displays. The container pushes every 10 min so the data is implicitly fresh; if the daemon dies, the per-pollutant numbers will look implausibly static — usable backstop without burning a row on a clock.
- **No category words in the right column.** Color encodes the category — green = Good, yellow = Moderate, orange = USG, etc. The "Gd"/"Mod" text was redundant and made the rows feel cluttered. **Accessibility note:** this layout is harder for color-blind users since color is the *only* category cue. Reasonable for a personal app; would need a redundant signal for broader audiences.
- **No pollutant label in the big tile.** The right column already shows each pollutant's AQI; the big number is one of them (the dominant), and matching is fast.
- **Forecast as weekday letters + colored dots.** Today is whatever weekday it is (`Su` for Sunday, etc.); tomorrow is the next day. Square color = AirNow forecast category for that day.
- **3-digit AQI handling:** ≤2 digits at `10x20` font, 3 digits at `6x13` fallback. "100" at `10x20` would be 30 px wide in a 28 px tile; the smaller font keeps it readable without clipping.

## Caching

`http.get(ttl_seconds=...)` is the upstream rate limiter:

| Endpoint | TTL | Hits/hour cap |
| --- | --- | --- |
| `LUR_pm_3day.json` | 300 s | 12 |
| `LUR_o3_stats.json` | 300 s | 12 |
| AirNow forecast | 1800 s | 2 |
| AirNow obs (fallback only) | 900 s | 4 (rare) |

## Notes and caveats

- BoulderAIR's JSONP feed is undocumented; the file path could change without notice. The check script catches that.
- AQI is computed from spot 5-min reads, not from the proper EPA rolling averages (24-hr NowCast for PM2.5, 8-hr for O3). Good enough for at-a-glance display; documented in `design-notes.md`. v2 should compute from the timeseries.
- This app uses no Open-Meteo / CAMS lookup. AirNow forecast is the only "outlook" source.
