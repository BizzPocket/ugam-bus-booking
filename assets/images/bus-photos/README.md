# Bus / destination photos

Stock photos used by tour cards on the customer browse surfaces. The
`UgamCard.media` variant expects a 16:9 photo placed inside an 8 px
outer card padding with a 16 px inner radius.

## Filenames (expected for Phase 1)

| File | Use |
|------|-----|
| `saputara.jpg` | Saputara hill station tours |
| `statue-of-unity.jpg` | Kevadia / Vadodara → Kevadia day trips |
| `diu.jpg` | Diu beach trips |
| `dwarka.jpg` | Dwarka temple tours |
| `ambaji.jpg` | Ambaji pilgrimage |
| `shirdi.jpg` | Shirdi pilgrimage |
| `lonavala.jpg` | Mumbai / Pune → Lonavala |
| `mahabaleshwar.jpg` | Mahabaleshwar hill station |

## Specs

- 1080 × 608 (16:9 at 2x)
- JPEG, target ≤ 80 KB after compression
- No text or watermark in the image (titles overlay via gradient)
- Composition leaves the bottom 40 % visually quiet (the title sits there
  with a black gradient overlay applied by `UgamCard.media`)
- Royalty-free + commercial-use OK (Unsplash, Pexels, or
  agent-supplied originals)

## Fallback

If a photo is missing at render time, the card falls back to a
brand-gradient tile with a bus icon. No errors.

## Phase 0 scope

Phase 0 only ships this README. The actual photos land alongside the
customer-flow redesign in Phase 1 so they can be cropped + colour-
balanced against the live UI.
