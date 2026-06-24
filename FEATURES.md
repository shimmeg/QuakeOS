# QuakeOS — Features

What QuakeOS currently does on the DK‑QUAKE / ARIS‑68 panel and in its macOS companion settings app.

## Home / OS layer

- **Springboard home screen** on the panel — a grid of app icons with a status bar (time, wifi, battery) and iOS‑style page dots.
- **Navigation:** knob press returns Home; swipe left/right to move between home pages; tap an icon to open that app.
- **Live video wallpapers** behind the home screen, set globally or per home page.
- **Configurable launch target** — open the panel to Home, a specific app/panel, or the last‑opened screen.

## Macro pages (tile grids)

- Editable **8×2 tile grids** (Apps / System / Web) rendered with DK‑Suite‑style glowing tiles.
- **Tile actions:** launch a macOS app, open a URL, run a shell command, run AppleScript, adjust panel brightness, or jump to another page.
- **Mac‑side Tile Editor** with a true 1:1 live device preview, a categorized drag‑and‑drop tile library, and a per‑tile inspector. Edits are a draft until you **Save to Quake**.
- Real app icons and website favicons resolved automatically for tiles.

## Clock app

- Three styles: **flip** (split‑flap), **digital**, and **analog**.
- **Single layout** — one clock fills the panel; swipe to flip between your time zones, with a dot indicator.
- **World‑grid layout** — multiple analog faces at once with each city's name and offset.
- Per‑clock label and time zone; global 12/24‑hour, seconds, and date toggles. Picking a city auto‑names the clock.

## Weather panel

- **Live current conditions** (Open‑Meteo, no API key): temperature, high/low, condition, and an animated condition icon.
- **Eight detail tiles:** precipitation chance, wind with gusts + a compass direction dial, air quality (US AQI with category), UV index, humidity, sunrise/sunset, "feels like," and moon phase with illumination.
- **Split left card:** current conditions on top, a **live precipitation radar map** below (RainViewer radar over a dark map, your location pinned) so you can see rain moving in.
- **Scrollable hourly forecast** with sunrise/sunset markers inline — drag the strip to scroll through the hours; a normal swipe anywhere else flips between your saved cities.
- **7‑day forecast** with high/low bars.
- **Multiple locations** you swipe through (with dots), plus **"Current Location"** resolved precisely via CoreLocation (with a permission prompt), falling back to IP geolocation.
- **Real‑time city search** in settings — type any city worldwide and add it.

## Music panel

- Now‑playing with artwork and queue (Spotify), shown on the panel.

## System Monitor panel

- Live CPU / GPU / memory / network / battery dashboard read from native macOS APIs.

## Performance — pre‑warmed panels

- Clock, Music, Monitor, and Weather panels are **built once at app launch and kept live**, so opening one is **instant** — no loading splash and no empty‑state flash. They keep refreshing in the background, so switching back always shows current data.

## Knob RGB ring

- QMK VIA lighting control: effect, color, brightness, and speed.
- **Reactive lighting** — page‑theme, music, and CPU‑driven modes.

## macOS settings app

- Dark "neon" sidebar design (Device / Panels / Lighting / Studio / Advanced).
- Live hero preview of the panel; a dockable inspector rail; dynamic dual‑sidebar collapse that adapts to window width.
- General settings: glow intensity, font, live‑preview placement, startup & menu‑bar behavior, language, and the device launch target.

---

*This list covers shipped functionality. On‑device Settings and Browser apps, the knob app‑switcher, and the Home Layout editor are also built. The Music panel's persistent switch‑in is implemented and pending on‑device verification.*
