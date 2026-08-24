# The updater never bypasses package checksum verification, and never suggests it

A package manager reporting a checksum mismatch cannot distinguish "the maintainer has not refreshed
stale metadata" from "you are being served a different file than the package declares"; the two are
byte-identical from where the updater stands. We therefore treat checksum verification as a boundary
the updater has no authority to cross: it will not pass `--ignore-checksums` (or any equivalent), and
that is deliberately not offered behind a flag such as `-AggressiveRepair`, which exists for repair
operations that do not weaken a verification boundary.

The repair plan for such a failure states the mismatch and prints the expected and actual hashes, so
a human can compare them against the vendor's published checksum. It deliberately does **not** name
the bypass command, even though the package manager's own error text does. A command in an error
message is a suggestion; the same command in a generated checklist that has been copied to the
reader's clipboard is an instruction, and it would be the path of least resistance at exactly the
moment the reader is least equipped to judge whether taking it is safe.

If you have arrived here because the repair plan seems unhelpfully incomplete: that is the decision,
not an oversight.
