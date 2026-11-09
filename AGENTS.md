# AGENTS.md

Read [CLAUDE.md](CLAUDE.md): it applies to you (Codex, Cursor, Gemini, any agent). The hard rules:

1. **Outward actions need the maintainer's yes**: pushing to GitHub, releases, tags and posts, each time.
2. **One task = one branch = one worktree**: never edit a checkout another agent may be using.
3. **Secrets by name only**: never print, commit or paste signing identities or credentials.
4. **Verification gate**: `swift build` without warnings, `make test` green, `make app` builds. SMC write paths are verified only by a person at the Mac running `sudo fanpilotctl test`. Never claim they work without it.
5. **Local notes**: if `CLAUDE.local.md` exists, read it too; it has maintainer- and machine-specific rules.

Also: never leave the `Ftst` SMC flag at 1. Every code path that takes the fans must give them back.
