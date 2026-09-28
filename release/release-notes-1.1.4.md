## Claude Cockpit 1.1.4

The second half of the 1.1.3 review: the smaller findings that were set aside,
each reproduced and pinned by a regression test.

### Fixed
- **The weekly cost insight compares like with like.** It used to set this week
  so far against the whole of last week, so early in the week it almost always
  announced a drop. It now compares with the same point last week, stays correct
  across a daylight-saving change, and stays quiet until a full day has passed
  and last week's figure reaches $1 — no more "+4900 %" on a Monday morning.
- **"Cette semaine" starts on Monday** whatever the system language, like the
  weekly cards.
- **Skill folders created after launch are picked up.** A watched folder that is
  deleted and recreated is watched again.
- **RTK live updates start on their own** when rtk is installed after Claude
  Cockpit was launched (within a minute), instead of waiting for a relaunch.
- **Sessions:** live indexing no longer retries every unlinked sub-agent in the
  archive on each change, and toggling system lines while a transcript loads no
  longer mixes the two views.

### Release process
- The DMG step retries a busy volume, and the notarization result is checked
  explicitly.
- The Sparkle tools are verified by checksum, and Sparkle is pinned to 2.10.0 —
  the version already shipped since 1.1.x.

`~/.claude` is still only ever opened for reading. No re-index this time.
