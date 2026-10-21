Images for the docs live here.

- `logo.svg` is the reference design for the app icon ("Queue" mark).
  `swift scripts/render-app-icon.swift` draws `logo.png` and every
  `AppIcon.appiconset` PNG from its own copy of that geometry, so an SVG
  edit must be mirrored in the script. Do not edit the PNGs by hand.
- Product screenshots: the root README currently embeds screenshots
  hosted on GitHub (user-attachments URLs). Drop local images here if you
  want to reference them from the docs/ guide instead, for example
  panel.png, inbox.png, keyboard.png, settings.png.
