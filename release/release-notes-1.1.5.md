## Claude Cockpit 1.1.5

### Fixed
- **The disk image has its layout back.** Since 1.1.3 the DMG opened as a plain
  window: the Finder scripting that arranged it could not run from the release
  environment, and the failure went unnoticed. The layout — background, large
  icons, Applications alias next to the app — is now written directly into the
  image, and the release fails if it is ever missing again.

The app itself is unchanged from 1.1.4. `~/.claude` is still only ever opened
for reading.
