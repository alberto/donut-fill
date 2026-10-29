# Donut Fill

Setup, layout and commands are in `README.md`. What an agent needs on top:

- Use the Makefile targets. `swift test` alone fails here: only the Command Line Tools are installed (no Xcode), and `make test` (`scripts/test.sh`) adds the Swift Testing search paths.
- Every build must be signed with the "Donut Fill Dev" identity, or Full Disk Access is lost on each rebuild. If `make app` falls back to ad-hoc signing, run `make cert` once.
- Check UI changes offscreen with `swift run DonutFill --snapshot <path> <out.png>` (see `README.md`) and show the image.
- Releases: `make release:patch` or `make release:minor` from a clean `main`. It tests, tags, pushes the tag and publishes the GitHub release.
- Icons and logos: ask for a reference image first. Show 3 to 5 options on one contact sheet (`scripts/contact_sheet.sh`) at real size, show every image inline, and give each iteration a new file name. SF Symbols are not allowed in app icons (Apple's license).
