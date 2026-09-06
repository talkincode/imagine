# Release Guide

## Automated Release Process

This project is configured with an automated CI/CD workflow that builds and publishes releases when new version tags (`v*`) are pushed or triggered manually.

## Release Steps

### 1. Update Version Information

Update the version number across the repository:

- `src/version.zig`: `pub const string = "x.y.z";`
- `build.zig.zon`: `.version = "x.y.z",`
- `README.md`: update `IMAGINE_VERSION=vx.y.z`
- `skills/imagine/SKILL.md`: update `IMAGINE_VERSION=vx.y.z`

Ensure unit tests pass:

```bash
make test
```

### 2. Commit Changes

```bash
git add README.md build.zig.zon skills/imagine/SKILL.md src/version.zig
git commit -m "Release vx.y.z"
git push origin main
```

### 3. Create and Push Tag

```bash
git tag -a vx.y.z -m "Release vx.y.z"
git push origin vx.y.z
```

### 4. Automated Build & Publishing

After pushing the tag, GitHub Actions (`.github/workflows/release.yml`) will automatically:

1. Build binaries for:
   - Linux x86_64 (`x86_64-linux-musl`)
   - Linux ARM64 (`aarch64-linux-musl`)
   - macOS x86_64 (`x86_64-macos`)
   - macOS ARM64 (`aarch64-macos`)
   - Windows x86_64 (`x86_64-windows`)
   - Windows ARM64 (`aarch64-windows`)
2. Package standalone binaries as well as `.tar.gz` archives (including the `skills` folder).
3. Generate `SHA256SUMS`.
4. Create the GitHub Release and upload all assets.
5. Publish/update the Homebrew tap formula in `talkincode/homebrew-tap` (if `HOMEBREW_TAP_TOKEN` is configured; see below).

---

## Homebrew Tap Publishing

On every release, the `homebrew` job in `.github/workflows/release.yml` renders and pushes `Formula/imagine.rb` to the `talkincode/homebrew-tap` repository, so users can install via:

```bash
brew install talkincode/tap/imagine
```

### Setup (one-time)

1. Create a fine-grained GitHub Personal Access Token (or classic PAT) with `repo` (or `Contents: write`) access to `talkincode/homebrew-tap`.
2. Add it as a repository secret named `HOMEBREW_TAP_TOKEN` in `talkincode/imagine` (Settings → Secrets and variables → Actions → Repository secrets).

If `HOMEBREW_TAP_TOKEN` is not set, the `homebrew` job safely no-ops and releases from forks or local builds will not fail.

### Verifying a Published Formula

```bash
brew tap talkincode/tap
brew install imagine
imagine version
```
