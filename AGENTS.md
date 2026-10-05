# Kiki - Agent Instructions

## Build & Run

The project directory, the `.xcodeproj` and the scheme are all `kiki-desktop-agent`; the app itself is `Kiki.app`, because `PRODUCT_NAME = Kiki`. The two names are deliberately different — the directory says what the project is, the product says what the user sees — and `PRODUCT_NAME` is what the test targets' `@testable import Kiki` has to match.

```bash
# Open in Xcode
open kiki-desktop-agent.xcodeproj

# Or build from the terminal (produces Kiki.app and kiki in DerivedData)
xcodebuild -project kiki-desktop-agent.xcodeproj -scheme kiki-desktop-agent -configuration Debug \
  CODE_SIGN_IDENTITY="Smarty Kiki Signing" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  build

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

The `kiki-desktop-agent` scheme is a **shared** scheme and builds both targets into the same `Build/Products/<configuration>/`, which is what lets the tool find `Kiki.app` as a sibling of itself. It is checked in at `xcshareddata/xcschemes/` deliberately: the automatic schemes xcodebuild generates are one per target, so without it `-scheme kiki-desktop-agent` would build the app and silently leave the tool stale. Building only the tool with `-scheme kiki` also works, and needs no app rebuild. The app target depends on the `kiki` target and embeds its product at `Kiki.app/Contents/Resources/kiki` through a copy-files phase carrying `CodeSignOnCopy`, so the nested tool is signed with the app and every release ships one file — in Resources rather than beside the app binary, where a copy named `kiki` would silently overwrite the app's own executable `Kiki` on a case-insensitive filesystem.

**Running `xcodebuild` from the terminal is safe.** An ad-hoc signature's Designated Requirement is a bare `cdhash`, so every rebuild would be a new identity to TCC; the self-signed certificate below is certificate-anchored instead, so grants survive rebuilds. **Launch with `open …/Kiki.app` when the permission state matters** — running the binary from a shell makes tccd answer Screen Recording for the terminal, not the app.

**Two GitHub Actions workflows cover the public flow, and both build ad-hoc** (`CODE_SIGN_IDENTITY="-"`, because no runner holds a certificate): `.github/workflows/ci.yml` builds both `Debug` and `Release` on every push to main and every pull request, as a build check only — the test targets are template stubs and UI tests are unreliable headless, so nothing is *run*. `.github/workflows/release.yml` fires on a `v*` tag and requires three versions to agree before it packages anything — the tag, the built app's `CFBundleShortVersionString` (`MARKETING_VERSION` on the app target) and a `## [X.Y.Z]` heading in CHANGELOG.md — then attaches a dmg (the app beside an Applications symlink) and a zip, each holding only `Kiki.app` with the `kiki` CLI embedded inside it by the app target's own copy phase, with SHA256 checksums and a build-provenance attestation, to a **draft** GitHub Release whose notes carry the changelog's section for that version. Re-pushing a tag whose draft already exists replaces the draft; a published release stops the run instead. The artifacts are ad-hoc and unnotarized, so the release notes carry the `xattr` command that strips the quarantine flag. The maintainer checklist and the one-time repository settings live in `RELEASING.md`; the self-signed certificate reaches neither workflow.

### Code Signing (self-signed certificate)

The app is signed with a local self-signed certificate named `Smarty Kiki Signing` rather than a real Apple Developer certificate. Nothing requires a Developer certificate — the app is not on the App Store and needs no provisioning profile — and the self-signed one is what makes TCC grants stick:

```
designated => identifier "com.smarty.kiki" and certificate root = H"ee5a2ca6f89d8ca593a7ccf0582da31449acaa83"
```

The `certificate root` clause is the point: it names the certificate, not any particular build, so a rebuilt binary still satisfies the requirement TCC recorded. An earlier certificate (`Clicky Local Signing`) is no longer in the login keychain, so builds naming it fail outright. Any future certificate swap costs one round of re-granting, then continuity resumes.

One build setting exists only because a self-signed certificate has no Team ID, and it is load-bearing — the app fails to launch without it:

- **`ENABLE_DEBUG_DYLIB = NO`** on Debug. Xcode's debug-dylib feature splits a Debug build into a stub executable plus `Kiki.debug.dylib`, and hardened runtime's library validation rejects that pairing when neither side carries a Team ID ("Library not loaded: @rpath/Kiki.debug.dylib"). Release builds are already a single binary and need nothing.

`com.apple.security.cs.disable-library-validation` is deliberately absent: with Sparkle removed there is no third-party framework for library validation to reject, so the app runs under the **full** hardened runtime. Do not reintroduce that entitlement without something concrete that needs it.

**`ENABLE_CODE_COVERAGE = NO`** is set on the project's Debug and Release configurations, and `kiki` depends on it. Coverage turns on LLVM's profile instrumentation, whose runtime writes a `default.profraw` into the process's working directory at exit — so every `kiki click` and `kiki command` would drop a file in whatever directory the caller was standing in. The app is unaffected either way: `/usr/bin/open` gives it `/` as its working directory, where that write fails silently.

**Bundle identifier is `com.smarty.kiki`.** `UserDefaults` is keyed on it, and so is the legacy Keychain item the DeepSeek key migrated out of — `DeepSeekAPIKeyStore` still addresses that name to read and delete it.

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Comments

- **Comments explain why, not what.** If a comment is needed to say what a line does, rename the thing instead. Code that reads plainly needs no comment above it.
- **English in code, Simplified Chinese for anything the user reads or hears.**
- **A log line carries no emoji.** `print`, `NSLog` and `os_log` say what happened in plain words: a pictograph is noise in a file that is read by `grep`, and it repeats what the sentence beside it already says. The modifier symbols are not emoji — ⌘⌥⌃⇧⎋⌫ in a key name are notation and stay.
- **Keep only what a reader cannot get from the code:**
  - System behaviour that is not visible in the source — a framework call that does something else as a side effect, a timer that stops firing in a particular run loop mode.
  - Why an obvious alternative is not usable, in one sentence.
  - Why a constant has the value it has, when it would otherwise look arbitrary.
  - "There must not be a second copy of this" warnings.
- **Delete the discovery narrative.** How something was found, what it measured, how many times it reproduced, what the old design did and why it was replaced — none of that belongs in the source. The *conclusion* stays if it justifies a constant or a shape; the process goes — and it goes for good, not into some other file.
- **Do not restate code, list branches the type names already make clear, or explain a call by its signature.** No bold or capital emphasis, no stacked examples, no rhetorical build-up.
- Use `//` for implementation notes and `///` for documentation. Documentation blocks are 2–4 lines, not multi-paragraph essays.
- Files with an already-low comment density (roughly ≤15% of lines) need a light pass at most. Pure token docs, such as `/// 8pt`, are not narrative and should be left alone.

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- **All user-facing copy is Simplified Chinese.** Every string the user reads or hears — panel labels, buttons, status text, the welcome message, the cursor's pointing bubbles, the spoken low-credits message — is written in Chinese directly in the source, not routed through a localization table. Product names and terms a Chinese developer would say in English (`Kiki`, `DeepSeek API Key`, `Control+Option`, model names like `Flash` / `V4 Pro`) stay in English.
- **What the user reads is said in Kiki's own voice, not the implementation's.** The task readout says the head is filling up (脑子用了 18% · 还有 82% 才满) rather than naming the threshold or the compression, because the number only means something to the user as something happening *to Kiki*. Identifiers, comments and this file keep the technical words; the split is by audience, not by concept.
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not delete logic on the grounds that the configuration it serves is not the one you are running — "I don't plug one in right now" is not "I never will".
- Do not rename `PRODUCT_NAME` away from `Kiki`, and do not rename `PRODUCT_BUNDLE_IDENTIFIER` away from `com.smarty.kiki` — `UserDefaults` is keyed on the identifier, so changing it orphans every setting the user has, the DeepSeek key among them, and the legacy Keychain item the key migrated out of is keyed on it too. The project directory and scheme being `kiki-desktop-agent` while the product is `Kiki` is deliberate, not a mismatch to tidy up
- Do not sign with an ad-hoc identity, and do not remove `ENABLE_DEBUG_DYLIB = NO` — see "Code Signing" for what it breaks. The CI and release workflows are the deliberate exception: a runner holds no certificate, and artifacts nobody rebuilds in place have no TCC persistence to lose

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main
