Load the spec for the given phase and summarize what needs to be built.

Usage: /spec <phase-number>   e.g. /spec 2

Read the file `specs/phase-$ARGUMENTS.md` in full. Then output:
1. The phase goal (one sentence)
2. Acceptance criteria as a numbered checklist
3. Key files to create
4. Key APIs / dependencies to use
5. Any risks or open questions called out in the spec

If no argument is given, list all spec files with their status line.
