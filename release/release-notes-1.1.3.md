## Claude Cockpit 1.1.3

A review release: every fix below was found by a code review of the whole app,
reproduced, and pinned by a regression test.

### Fixed
- **Token and cost figures were too low — expect them to go up.** Claude Code
  writes one transcript line per content block of a response, and the usage
  grows from one line to the next. Only the first, smallest line was counted.
  Each token field now takes the largest value across a response's lines, and
  the response is still counted once. On a real archive this adds back about
  **15–17 % of output tokens**, mostly in sub-agent transcripts. The higher
  numbers are the correct ones, in both Usage and Sessions.
- **Stars, custom names and hidden sessions survive an index upgrade.** A
  change of index format used to rebuild the database and silently drop them.
  This release upgrades the index once on first launch and keeps them all.
- **Renaming a project folder no longer erases its sessions.** A transcript
  that moved was treated as new and its session deleted, marks included. It is
  now re-read from its new path.
- **Symlinked skills are listed.** Skills linked into `~/.claude/skills` (for
  example from `~/.agents`) were invisible. They now appear, marked as links;
  copy, move and delete are disabled on them, since those would act on the link
  rather than its target. A transfer onto a folder that resolves to the source
  is refused, and a move now checks the copy before removing the original.
- **Menu-bar-only mode keeps its promise.** Opening the cockpit window no longer
  leaves a Dock icon behind once the window is closed.
- **"Reconstruire l'index" can no longer get stuck disabled** after a failed
  indexing pass.
- Search: a query containing `**` no longer returns nothing; a message shared by
  a resumed and a forked session shows up in both; a stale search can no longer
  overwrite newer results.
- A transcript truncated to nothing drops its old rows; a deleted sub-agent no
  longer leaves an Agent card pointing at an empty transcript.
- Project labels: `/Users/vincent2/app` is no longer shortened to `~2/app`.

`~/.claude` is still only ever opened for reading. The first launch re-indexes
your transcripts once (about 20–30 s on a large archive).
