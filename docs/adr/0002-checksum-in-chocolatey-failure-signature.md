# The expected checksum is part of a Chocolatey failure signature

A failure signature identifies *what went wrong* so the updater can recognise the same failure
recurring across passes and stop retrying something that provably cannot succeed. Winget composes
its signature from package ID and exit code, which works because Winget's exit codes are meaningful.
Chocolatey reports `exited -1` for every failing install script — checksum mismatch, disk exhaustion,
and a network drop are indistinguishable by code — so the same composition would treat two unrelated
failures of one package as the same failure repeating, and escalate to terminal on that basis.

For checksum failures we therefore fold the **expected** hash into the signature, falling back to
package and code for everything else. Beyond discriminating causes, this makes the signature
self-healing: when the maintainer refreshes the package metadata the expected hash changes, so the
signature changes, the repeat counter resets, and the updater retries on its own. Under a
code-only signature the terminal verdict would outlive the problem, and a human would have to
intervene to unstick something that had already fixed itself upstream.

Consequence: signatures are not comparable across a change to this composition. Changing what goes
into a signature invalidates any stored one, which is safe (it reads as a new failure and re-arms
the retry budget) but means the counter restarts for every in-flight failure.
