# Contributing to Soro

Thanks for your interest in Soro. Contributions are welcome.

## Prerequisites

- macOS 14 (Sonoma) or later, Apple Silicon
- Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- [Ollama](https://ollama.com) (optional, for cleanup features): `brew install ollama`

## Build

The Xcode project is generated from `project.yml` and is **not** checked in.
Regenerate it after cloning (or whenever `project.yml` changes):

```bash
xcodegen generate
xcodebuild -project Soro.xcodeproj -scheme Soro -destination 'platform=macOS' build
```

Or open `Soro.xcodeproj` in Xcode and build the `Soro` scheme.

By default the app builds with **ad-hoc** signing (`CODE_SIGN_IDENTITY="-"`), so
no Apple Developer account or certificate is required.

## Run tests

```bash
xcodebuild -project Soro.xcodeproj -scheme Soro -destination 'platform=macOS' test
```

## Code style

- Swift / SwiftUI, following the existing conventions in the tree.
- Keep modules small and testable; add or update unit tests for behavior changes.
- Prefer pure, injectable logic (see `DataMigration.shouldMigrate` for the pattern).

## Pull requests

- Keep PRs focused and describe the change and how you tested it.
- Make sure `xcodegen generate` and the full test suite pass before opening a PR.
- By contributing, you agree your contributions are licensed under the project's
  [MIT License](LICENSE).
