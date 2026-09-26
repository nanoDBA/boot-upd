# Reviewed sources

The upstream skills are installed separately. This project skill adds the user's
requirements, technical-preservation checks, and examples from the documentation review.
It does not run an authorship-classification service.

- [ryanmaule/humanize](https://github.com/ryanmaule/humanize/tree/4a8bbcf74984dad5bdad10177afe766e32bc7633): reviewed and installed at commit `4a8bbcf74984dad5bdad10177afe766e32bc7633`. Use `SKILL.md` for editing or named-pattern audits, and `eval.md` for its post-edit checks.
- [blader/humanizer](https://github.com/blader/humanizer/tree/9862685f575c65a8247f90369951df1b3416e3d6): reviewed and installed at commit `9862685f575c65a8247f90369951df1b3416e3d6`. Use its `SKILL.md` pattern catalog for a final audit, especially structural patterns that survive word substitutions.

Treat blanket punctuation bans and broad word blacklists as editing suggestions when
they conflict with the user's voice, technical accuracy, or protected commands. Neither
source establishes that removing patterns makes text human-authored or undetectable.

The canonical project skill lives in `.agents/skills/humanize-docs`. A copy can be
installed in the agent's personal skills directory for use outside this checkout.
Update that installed copy when changing the project skill; keep upstream installs
separate so their origin and revisions remain clear.
