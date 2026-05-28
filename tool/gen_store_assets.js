#!/usr/bin/env node
/*
 * Generates Google Play store listing assets for Ugam Foj using the bundled
 * Chrome for Testing as a headless renderer. Outputs to ../store_assets/.
 *
 *   - feature_graphic.png   1024 x 500   (required)
 *   - app_icon.png           512 x 512   (required)
 *   - screen_1..4.png       1080 x 1920  (phone screenshots, 9:16)
 *
 * Run: node tool/gen_store_assets.js
 */
const { execFileSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const os = require("os");

const CHROME =
  "/Users/zeelshiyani/.cache/puppeteer/chrome/mac_arm-148.0.7778.97/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing";

const OUT = path.join(__dirname, "..", "store_assets");
fs.mkdirSync(OUT, { recursive: true });
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "ugam-assets-"));

// ---- Brand tokens (from lib/design/tokens.dart + logo svg) -----------------
const C = {
  cream: "#FBF3EC",
  creamElev: "#F3E8DD",
  creamBorder: "#E7DACE",
  terracotta: "#C56A3F",
  terracottaBright: "#E07A4F",
  rays: "#D2794B",
  brown: "#4A2F25",
  brownMuted: "#8A6F5F",
  // dark theme
  bg: "#0A0A0A",
  card: "#171717",
  cardElev: "#262626",
  border: "#333333",
  ink: "#FAFAFA",
  ink2: "#A3A3A3",
  ink3: "#737373",
  good: "#10B981",
  warm: "#F59E0B",
};

// ---- The logo mark (rising sun + word-mark + yatra bus), inline SVG --------
// Reused verbatim from assets/icon/ugam_logo.svg, parameterised by background.
function logoMark({ bg = C.cream } = {}) {
  return `<svg viewBox="0 0 1024 1024" width="100%" height="100%" xmlns="http://www.w3.org/2000/svg">
    <rect width="1024" height="1024" rx="180" fill="${bg}"/>
    <g fill="${C.rays}">
      <polygon points="275.9,454.8 272.2,482.6 105.5,446.5"/><polygon points="283.8,424.4 276.6,451.4 116.0,393.9"/>
      <polygon points="294.1,398.9 286.4,417.4 188.6,366.1"/><polygon points="311.2,367.9 297.2,392.1 156.9,295.0"/>
      <polygon points="327.7,346.0 315.5,361.8 234.3,286.9"/><polygon points="352.2,320.4 332.4,340.2 222.1,210.1"/>
      <polygon points="373.8,303.5 358.0,315.7 298.9,222.3"/><polygon points="404.1,285.2 379.9,299.2 307.0,144.9"/>
      <polygon points="429.4,274.4 410.9,282.1 378.1,176.6"/><polygon points="463.4,264.6 436.4,271.8 405.9,104.0"/>
      <polygon points="490.6,260.7 470.8,263.4 466.3,153.0"/><polygon points="526.0,260.0 498.0,260.0 512.0,90.0"/>
      <polygon points="553.2,263.4 533.4,260.7 557.7,153.0"/><polygon points="587.6,271.8 560.6,264.6 618.1,104.0"/>
      <polygon points="613.1,282.1 594.6,274.4 645.9,176.6"/><polygon points="644.1,299.2 619.9,285.2 717.0,144.9"/>
      <polygon points="666.0,315.7 650.2,303.5 725.1,222.3"/><polygon points="691.6,340.2 671.8,320.4 801.9,210.1"/>
      <polygon points="708.5,361.8 696.3,346.0 789.7,286.9"/><polygon points="726.8,392.1 712.8,367.9 867.1,295.0"/>
      <polygon points="737.6,417.4 729.9,398.9 835.4,366.1"/><polygon points="747.4,451.4 740.2,424.4 908.0,393.9"/>
      <polygon points="751.8,482.6 748.1,454.8 918.5,446.5"/>
    </g>
    <path d="M 262 500 A 250 250 0 0 1 762 500 Z" fill="${C.terracotta}"/>
    <text x="512" y="455" text-anchor="middle"
      font-family="Kohinoor Gujarati, Gujarati Sangam MN, GujaratiMT, Noto Sans Gujarati, sans-serif"
      font-weight="800" font-size="138" fill="${C.cream}">ઉગમ</text>
    <g>
      <rect x="236" y="522" width="552" height="148" rx="34" fill="${C.brown}"/>
      <g fill="${C.cream}">
        <rect x="270" y="550" width="86" height="56" rx="10"/><rect x="368" y="550" width="86" height="56" rx="10"/>
        <rect x="466" y="550" width="86" height="56" rx="10"/><rect x="564" y="550" width="86" height="56" rx="10"/>
        <rect x="662" y="550" width="92" height="56" rx="10"/>
      </g>
      <circle cx="772" cy="642" r="13" fill="${C.rays}"/>
      <g fill="${C.brown}"><circle cx="346" cy="690" r="48"/><circle cx="678" cy="690" r="48"/></g>
      <g fill="${C.cream}"><circle cx="346" cy="690" r="17"/><circle cx="678" cy="690" r="17"/></g>
    </g>
  </svg>`;
}

const FONT =
  '-apple-system, "SF Pro Display", "Helvetica Neue", Arial, sans-serif';

function frame(w, h, inner, bodyCss = "") {
  return `<!doctype html><html><head><meta charset="utf-8"><style>
    *{margin:0;padding:0;box-sizing:border-box;}
    html,body{width:${w}px;height:${h}px;overflow:hidden;font-family:${FONT};-webkit-font-smoothing:antialiased;}
    ${bodyCss}
  </style></head><body>${inner}</body></html>`;
}

// ============================ FEATURE GRAPHIC ===============================
function featureGraphic() {
  const inner = `
  <div class="wrap">
    <div class="rays"></div>
    <div class="badge">${logoMark({ bg: C.cream })}</div>
    <div class="copy">
      <div class="brand">Ugam&nbsp;Foj</div>
      <div class="tag">Group yatra bus tours —<br>browse trips, pick your seat, book.</div>
      <div class="pill">ઉગમ ફોજ • DEVAM</div>
    </div>
  </div>`;
  const css = `
    .wrap{width:1024px;height:500px;position:relative;display:flex;align-items:center;gap:56px;
      padding:0 80px;background:radial-gradient(120% 140% at 18% 30%, ${C.brown} 0%, #2A1A14 55%, #160D0A 100%);overflow:hidden;}
    .rays{position:absolute;right:-160px;top:-160px;width:620px;height:620px;border-radius:50%;
      background:radial-gradient(circle, ${C.terracotta}55 0%, ${C.terracotta}00 62%);}
    .badge{width:300px;height:300px;flex:0 0 auto;border-radius:64px;overflow:hidden;
      box-shadow:0 30px 70px rgba(0,0,0,.55), 0 0 0 1px rgba(255,255,255,.06);position:relative;z-index:2;}
    .copy{position:relative;z-index:2;}
    .brand{font-size:96px;font-weight:800;color:${C.cream};letter-spacing:-2px;line-height:.95;}
    .tag{margin-top:22px;font-size:34px;font-weight:600;color:#EBD9CC;line-height:1.28;}
    .pill{margin-top:30px;display:inline-block;padding:12px 26px;border-radius:999px;
      background:${C.terracottaBright};color:#fff;font-size:22px;font-weight:700;letter-spacing:.5px;}`;
  return frame(1024, 500, inner, css);
}

// ============================== APP ICON ====================================
function appIcon() {
  return frame(
    512,
    512,
    `<div style="width:512px;height:512px;">${logoMark({ bg: C.cream })}</div>`
  );
}

// ====================== PHONE SCREENSHOT SCAFFOLD ===========================
// Caption band on top (brand), then the app UI mock below on dark bg.
function phone({ caption, sub, body }) {
  const inner = `
    <div class="cap">
      <div class="ctitle">${caption}</div>
      <div class="csub">${sub}</div>
    </div>
    <div class="app">
      <div class="statusbar"><span>9:41</span><span>▦ ▾ ▮▮▮</span></div>
      ${body}
    </div>`;
  const css = `
    body{background:${C.bg};display:flex;flex-direction:column;}
    .cap{padding:74px 70px 40px;background:linear-gradient(135deg, ${C.brown} 0%, #2A1A14 100%);}
    .ctitle{font-size:62px;font-weight:800;color:${C.cream};line-height:1.05;letter-spacing:-1px;}
    .csub{margin-top:18px;font-size:30px;font-weight:500;color:${C.terracottaBright};}
    .app{flex:1;background:${C.bg};border-top:1px solid ${C.border};padding:0 40px 40px;overflow:hidden;}
    .statusbar{display:flex;justify-content:space-between;align-items:center;color:${C.ink2};
      font-size:26px;font-weight:600;padding:26px 6px 30px;}
    .card{background:${C.card};border:1px solid ${C.border};border-radius:30px;padding:34px;margin-bottom:26px;}
    .row{display:flex;align-items:center;justify-content:space-between;}
    .h1{font-size:40px;font-weight:800;color:${C.ink};letter-spacing:-.5px;}
    .h2{font-size:36px;font-weight:700;color:${C.ink};}
    .muted{color:${C.ink2};font-size:28px;font-weight:500;}
    .muted3{color:${C.ink3};font-size:25px;font-weight:500;}
    .chip{display:inline-flex;align-items:center;gap:10px;padding:12px 22px;border-radius:999px;font-size:25px;font-weight:700;}
    .accent{color:${C.terracottaBright};}
    .btn{background:${C.terracottaBright};color:#fff;font-size:34px;font-weight:800;text-align:center;
      padding:34px;border-radius:24px;margin-top:8px;}`;
  return frame(1080, 1920, inner, css);
}

// Screen 1 — Browse tours
function screen1() {
  const tour = (route, date, left, price, accent) => `
    <div class="card">
      <div class="row"><div class="h2">${route}</div><div class="chip" style="background:${C.terracottaBright}22;color:${C.terracottaBright}">₹${price}</div></div>
      <div class="muted" style="margin-top:16px;">🗓  ${date}</div>
      <div class="row" style="margin-top:28px;">
        <div class="muted3">🚌 Sleeper coach</div>
        <div class="chip" style="background:${accent}22;color:${accent}">${left} seats left</div>
      </div>
    </div>`;
  const body = `
    <div class="row" style="margin-bottom:30px;">
      <div class="h1">Upcoming Yatras</div>
      <div class="chip" style="background:${C.card};color:${C.ink2};border:1px solid ${C.border}">All ▾</div>
    </div>
    ${tour("Bhedapipaliya Dham", "12 Jun 2026 · 6:00 AM", 8, "1,200", C.good)}
    ${tour("Dwarka – Somnath", "21 Jun 2026 · 5:30 AM", 3, "2,400", C.warm)}
    ${tour("Ambaji Darshan", "04 Jul 2026 · 7:00 AM", 22, "900", C.good)}`;
  return phone({
    caption: "Browse every<br>upcoming yatra",
    sub: "Routes, dates & seats — all in one place",
    body,
  });
}

// Screen 2 — Seat selection
function screen2() {
  const seat = (state) => {
    let bg = "transparent",
      bd = C.border,
      fg = C.ink2;
    if (state === "sel") { bg = C.terracottaBright; bd = C.terracottaBright; fg = "#fff"; }
    if (state === "taken") { bg = C.cardElev; bd = C.cardElev; fg = C.ink3; }
    if (state === "ladies") { bg = `${C.warm}22`; bd = C.warm; fg = C.warm; }
    return `<div style="width:96px;height:96px;border-radius:18px;border:2px solid ${bd};background:${bg};
      display:flex;align-items:center;justify-content:center;color:${fg};font-size:30px;font-weight:700;">▦</div>`;
  };
  const rowSeats = (a, b, c, d) =>
    `<div class="row" style="margin-bottom:22px;">
       <div style="display:flex;gap:18px;">${seat(a)}${seat(b)}</div>
       <div style="display:flex;gap:18px;">${seat(c)}${seat(d)}</div>
     </div>`;
  const body = `
    <div class="h1" style="margin-bottom:10px;">Choose your seat</div>
    <div class="muted" style="margin-bottom:34px;">Bhedapipaliya Dham · 12 Jun</div>
    <div class="card" style="padding:40px 44px;">
      <div class="row" style="margin-bottom:34px;color:${C.ink2};font-size:25px;font-weight:600;">
        <span>Driver 🚍</span><span>Double-sofa rows</span>
      </div>
      ${rowSeats("taken", "sel", "free", "free")}
      ${rowSeats("free", "free", "ladies", "ladies")}
      ${rowSeats("taken", "taken", "free", "free")}
      ${rowSeats("free", "free", "free", "free")}
    </div>
    <div class="row" style="font-size:25px;font-weight:600;color:${C.ink2};margin-top:4px;">
      <span class="accent">▦ Selected</span><span style="color:${C.warm}">▦ Ladies</span><span style="color:${C.ink3}">▦ Booked</span>
    </div>`;
  return phone({
    caption: "Pick your<br>exact seat",
    sub: "Visual seat map with paired sofa seats",
    body,
  });
}

// Screen 3 — Booking request form
function screen3() {
  const field = (label, val, ph) => `
    <div style="margin-bottom:28px;">
      <div class="muted3" style="margin-bottom:12px;">${label}</div>
      <div style="background:${C.card};border:1px solid ${C.border};border-radius:20px;padding:30px 28px;
        font-size:32px;font-weight:600;color:${val ? C.ink : C.ink3};">${val || ph}</div>
    </div>`;
  const body = `
    <div class="h1" style="margin-bottom:34px;">Your booking</div>
    ${field("Full name", "Rameshbhai Patel", "")}
    ${field("Mobile number", "+91 98250 12345", "")}
    <div class="row" style="gap:26px;">
      <div style="flex:1;">${field("Seats", "2", "")}</div>
      <div style="flex:1;">${field("Boarding point", "Rajkot", "")}</div>
    </div>
    <div class="card" style="background:${C.terracottaBright}14;border-color:${C.terracottaBright}55;">
      <div class="row"><div class="muted">Seats 14, 15 · Bhedapipaliya</div><div class="h2 accent">₹2,400</div></div>
    </div>
    <div class="btn">Send booking request</div>`;
  return phone({
    caption: "Book in a<br>few taps",
    sub: "Your request reaches the organiser instantly",
    body,
  });
}

// Screen 4 — My requests
function screen4() {
  const req = (route, date, seats, status, color) => `
    <div class="card">
      <div class="row"><div class="h2">${route}</div>
        <div class="chip" style="background:${color}22;color:${color}">${status}</div></div>
      <div class="muted" style="margin-top:16px;">🗓 ${date}</div>
      <div class="muted3" style="margin-top:14px;">Seats ${seats}</div>
    </div>`;
  const body = `
    <div class="h1" style="margin-bottom:30px;">My requests</div>
    ${req("Bhedapipaliya Dham", "12 Jun 2026", "14, 15", "Confirmed ✓", C.good)}
    ${req("Dwarka – Somnath", "21 Jun 2026", "07", "Pending", C.warm)}
    ${req("Ambaji Darshan", "04 Jul 2026", "31, 32", "Confirmed ✓", C.good)}`;
  return phone({
    caption: "Track all your<br>requests",
    sub: "Watch each booking go from sent to confirmed",
    body,
  });
}

// ================================ RENDER ====================================
const jobs = [
  { name: "feature_graphic", html: featureGraphic(), w: 1024, h: 500 },
  { name: "app_icon", html: appIcon(), w: 512, h: 512 },
  { name: "screen_1_browse", html: screen1(), w: 1080, h: 1920 },
  { name: "screen_2_seats", html: screen2(), w: 1080, h: 1920 },
  { name: "screen_3_booking", html: screen3(), w: 1080, h: 1920 },
  { name: "screen_4_requests", html: screen4(), w: 1080, h: 1920 },
];

for (const j of jobs) {
  const htmlPath = path.join(TMP, `${j.name}.html`);
  const outPath = path.join(OUT, `${j.name}.png`);
  fs.writeFileSync(htmlPath, j.html);
  execFileSync(
    CHROME,
    [
      "--headless=new",
      "--disable-gpu",
      "--hide-scrollbars",
      "--force-device-scale-factor=1",
      `--screenshot=${outPath}`,
      `--window-size=${j.w},${j.h}`,
      "--allow-file-access-from-files",
      `file://${htmlPath}`,
    ],
    { stdio: "ignore" }
  );
  const sz = fs.statSync(outPath).size;
  console.log(`✓ ${j.name}.png  ${j.w}x${j.h}  (${(sz / 1024).toFixed(0)} KB)`);
}
console.log(`\nAll assets written to: ${OUT}`);
