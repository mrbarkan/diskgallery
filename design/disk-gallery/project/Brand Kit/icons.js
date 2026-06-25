/* =========================================================
   DiskGallery — app icon generator
   One source of truth for the mark, rendered as scalable SVG
   so a single glyph drives the squircle previews, the macOS
   size ladder, the Dock, the splash and the About window.

   makeIcon(variant, size) -> <svg> string
   variants: "vault" | "solid" | "locator" | "plate"
========================================================= */
(function () {
  let _seq = 0;

  // Smooth super-elliptical squircle (Apple-style continuous corners), 0..100 box.
  const SQUIRCLE =
    "M50 2 C16 2 2 16 2 50 C2 84 16 98 50 98 C84 98 98 84 98 50 C98 16 84 2 50 2 Z";

  // ---- shared glyph pieces (100x100 viewBox, art ~24..76) ----
  function dataLines(c1, c2) {
    return (
      `<rect x="33" y="50.5" width="30" height="4.2" rx="2.1" fill="${c1}"/>` +
      `<rect x="33" y="59.5" width="20" height="4.2" rx="2.1" fill="${c2}"/>`
    );
  }

  function makeIcon(variant, size) {
    const u = "dg" + ++_seq + "_";
    const px = size || 220;
    let defs = "";
    let bg = "";
    let glyph = "";

    if (variant === "vault") {
      // Deep OLED black tile, violet glow, monoline drive — the signature look.
      defs =
        `<linearGradient id="${u}body" x1="0" y1="0" x2="0" y2="1">` +
          `<stop offset="0" stop-color="#bda7ff"/><stop offset="1" stop-color="#8f6cff"/></linearGradient>` +
        `<radialGradient id="${u}tile" cx="0.28" cy="0.2" r="0.95">` +
          `<stop offset="0" stop-color="#15101f"/><stop offset="0.5" stop-color="#0a0b11"/>` +
          `<stop offset="1" stop-color="#050608"/></radialGradient>` +
        `<radialGradient id="${u}halo" cx="0.3" cy="0.22" r="0.5">` +
          `<stop offset="0" stop-color="#a78bff" stop-opacity="0.55"/>` +
          `<stop offset="1" stop-color="#a78bff" stop-opacity="0"/></radialGradient>` +
        ledFilter(u);
      bg =
        `<path d="${SQUIRCLE}" fill="url(#${u}tile)"/>` +
        `<path d="${SQUIRCLE}" fill="url(#${u}halo)"/>` +
        `<path d="${SQUIRCLE}" fill="none" stroke="rgba(255,255,255,0.10)" stroke-width="1"/>`;
      glyph =
        `<rect x="26" y="29" width="48" height="42" rx="9" fill="none" stroke="url(#${u}body)" stroke-width="3.6"/>` +
        `<line x1="29.5" y1="43.5" x2="70.5" y2="43.5" stroke="url(#${u}body)" stroke-width="3" stroke-linecap="round"/>` +
        `<circle cx="33.6" cy="36.5" r="2.9" fill="#4ade80" filter="url(#${u}glow)"/>` +
        dataLines("#a78bff", "rgba(167,139,255,0.5)");
    }

    else if (variant === "solid") {
      // Bold violet tile, dark knockout glyph — maximum Dock presence.
      defs =
        `<linearGradient id="${u}tile" x1="0.1" y1="0" x2="0.9" y2="1">` +
          `<stop offset="0" stop-color="#b89dff"/><stop offset="0.55" stop-color="#8f6cff"/>` +
          `<stop offset="1" stop-color="#6f4ce0"/></linearGradient>` +
        `<radialGradient id="${u}sheen" cx="0.3" cy="0.12" r="0.7">` +
          `<stop offset="0" stop-color="#ffffff" stop-opacity="0.4"/>` +
          `<stop offset="1" stop-color="#ffffff" stop-opacity="0"/></radialGradient>`;
      bg =
        `<path d="${SQUIRCLE}" fill="url(#${u}tile)"/>` +
        `<path d="${SQUIRCLE}" fill="url(#${u}sheen)"/>` +
        `<path d="${SQUIRCLE}" fill="none" stroke="rgba(255,255,255,0.22)" stroke-width="1"/>`;
      const ink = "#1c1430";
      glyph =
        `<rect x="26" y="29" width="48" height="42" rx="9" fill="none" stroke="${ink}" stroke-width="3.8"/>` +
        `<line x1="29.5" y1="43.5" x2="70.5" y2="43.5" stroke="${ink}" stroke-width="3.1" stroke-linecap="round"/>` +
        `<circle cx="33.6" cy="36.5" r="2.9" fill="#1c1430"/>` +
        `<circle cx="33.6" cy="36.5" r="1.3" fill="#5fe39a"/>` +
        dataLines(ink, "rgba(28,20,48,0.55)");
    }

    else if (variant === "locator") {
      // Graphite "map" tile with a you-are-here locator inside the drive.
      defs =
        `<linearGradient id="${u}body" x1="0" y1="0" x2="0" y2="1">` +
          `<stop offset="0" stop-color="#bda7ff"/><stop offset="1" stop-color="#8f6cff"/></linearGradient>` +
        `<linearGradient id="${u}tile" x1="0" y1="0" x2="1" y2="1">` +
          `<stop offset="0" stop-color="#161922"/><stop offset="1" stop-color="#0a0c11"/></linearGradient>` +
        `<pattern id="${u}grid" width="9" height="9" patternUnits="userSpaceOnUse">` +
          `<circle cx="1" cy="1" r="0.8" fill="rgba(167,139,255,0.14)"/></pattern>` +
        ledFilter(u);
      bg =
        `<path d="${SQUIRCLE}" fill="url(#${u}tile)"/>` +
        `<path d="${SQUIRCLE}" fill="url(#${u}grid)"/>` +
        `<path d="${SQUIRCLE}" fill="none" stroke="rgba(255,255,255,0.09)" stroke-width="1"/>`;
      glyph =
        `<rect x="26" y="29" width="48" height="42" rx="9" fill="none" stroke="url(#${u}body)" stroke-width="3.6"/>` +
        `<line x1="29.5" y1="43.5" x2="70.5" y2="43.5" stroke="url(#${u}body)" stroke-width="3" stroke-linecap="round"/>` +
        // crosshair ticks
        `<g stroke="rgba(167,139,255,0.55)" stroke-width="2" stroke-linecap="round">` +
          `<line x1="50" y1="48.5" x2="50" y2="51.5"/><line x1="50" y1="66.5" x2="50" y2="69.5"/>` +
          `<line x1="31.5" y1="59" x2="34.5" y2="59"/><line x1="65.5" y1="59" x2="68.5" y2="59"/></g>` +
        // you-are-here rings
        `<circle cx="50" cy="59" r="8" fill="none" stroke="#4ade80" stroke-width="1.8" stroke-opacity="0.5"/>` +
        `<circle cx="50" cy="59" r="4.4" fill="none" stroke="#4ade80" stroke-width="2"/>` +
        `<circle cx="50" cy="59" r="1.9" fill="#4ade80" filter="url(#${u}glow)"/>`;
    }

    else { // plate
      // Dimensional graphite tile, glossy violet faceplate.
      defs =
        `<linearGradient id="${u}tile" x1="0" y1="0" x2="0" y2="1">` +
          `<stop offset="0" stop-color="#222632"/><stop offset="1" stop-color="#0d0f15"/></linearGradient>` +
        `<linearGradient id="${u}sheen" x1="0" y1="0" x2="0" y2="1">` +
          `<stop offset="0" stop-color="#ffffff" stop-opacity="0.16"/>` +
          `<stop offset="0.5" stop-color="#ffffff" stop-opacity="0"/></linearGradient>` +
        `<linearGradient id="${u}plate" x1="0" y1="0" x2="0" y2="1">` +
          `<stop offset="0" stop-color="#b69cff"/><stop offset="1" stop-color="#7d59ec"/></linearGradient>` +
        ledFilter(u);
      bg =
        `<path d="${SQUIRCLE}" fill="url(#${u}tile)"/>` +
        `<path d="${SQUIRCLE}" fill="url(#${u}sheen)"/>` +
        `<path d="${SQUIRCLE}" fill="none" stroke="rgba(255,255,255,0.10)" stroke-width="1"/>`;
      const ink = "#1d1633";
      glyph =
        `<rect x="26" y="29" width="48" height="42" rx="9" fill="url(#${u}plate)"/>` +
        `<rect x="26" y="29" width="48" height="42" rx="9" fill="none" stroke="rgba(255,255,255,0.25)" stroke-width="1"/>` +
        `<line x1="29.5" y1="43.5" x2="70.5" y2="43.5" stroke="${ink}" stroke-width="2.6" stroke-linecap="round" stroke-opacity="0.55"/>` +
        `<circle cx="33.6" cy="36.5" r="2.9" fill="#4ade80" filter="url(#${u}glow)"/>` +
        dataLines("rgba(29,22,51,0.85)", "rgba(29,22,51,0.5)");
    }

    return (
      `<svg class="dg-icon" width="${px}" height="${px}" viewBox="0 0 100 100" ` +
      `xmlns="http://www.w3.org/2000/svg" role="img" aria-label="DiskGallery app icon">` +
      `<defs>${defs}</defs>${bg}${glyph}</svg>`
    );
  }

  function ledFilter(u) {
    return (
      `<filter id="${u}glow" x="-120%" y="-120%" width="340%" height="340%">` +
      `<feGaussianBlur stdDeviation="2.2" result="b"/>` +
      `<feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>`
    );
  }

  // Fill every [data-icon] placeholder: variant from data-icon, size from data-size.
  function paint(root) {
    (root || document).querySelectorAll("[data-icon]").forEach(function (el) {
      const v = el.getAttribute("data-icon");
      const s = parseInt(el.getAttribute("data-size") || "0", 10) || el.clientWidth || 64;
      el.innerHTML = makeIcon(v, s);
    });
  }

  window.DGIcon = { make: makeIcon, paint: paint };
  if (document.readyState !== "loading") paint();
  else document.addEventListener("DOMContentLoaded", function () { paint(); });
})();
