# Screenshots

**This folder is deliberately empty of images, and that is an honest statement rather than an
oversight.**

The build pipeline that produced this repository attempts to launch the demo on a real iOS
Simulator and capture the result. On this run it did not get that far: the screenshot it took of
the machine first showed Xcode holding an unrelated, active piece of work — a different app on a
feature branch, mid-edit. The pipeline's own rule for that situation is to abort rather than click
through somebody else's session, so it aborted.

No mockups, no AI-generated "screenshots", and no renders of what the UI would look like have been
substituted. When the demo is first launched by a human, the screenshots taken then will be the
first real images of it, and they belong here.

What *was* verified is documented in the repository README and in the library repository:
`swift build` clean with zero warnings, 71/71 tests passing, and a static audit of the sources.
The Demo target itself has never been compiled — `swiftc -parse` is a syntax check, not a build.
