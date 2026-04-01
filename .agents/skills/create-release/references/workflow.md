# OpenWhisper Release

## Prerequisites

Confirm before starting:
- `Developer ID Application` certificate in keychain
- Sparkle EdDSA key (`.build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys`)
- Notarization credentials (`xcrun notarytool store-credentials notarytool`)
- CLI tools: `xcodegen`, `gh`

## Workflow

### 1. Get the version

Ask the user for the version number if not provided (e.g. `0.4.0`). Set `TAG=v<VERSION>`.

### 2. Run the release script

```bash
scripts/create_release.sh <VERSION>
```

This builds, signs, notarizes, creates a DMG, signs it with Sparkle, and updates `appcast.xml`. Stream output so the user can monitor progress. The script may take several minutes.

If the script fails, diagnose the error and report it. Do not proceed.

### 3. Tag and push

After the script succeeds:

```bash
git tag v<VERSION>
git push origin v<VERSION>
```

### 4. Create the GitHub release

```bash
gh release create v<VERSION> \
  --repo richardwu/openwhisper \
  --title "OpenWhisper <VERSION>" \
  --generate-notes \
  .release/OpenWhisper.dmg
```

Verify the release was created by checking the output URL.

### 5. Commit and push appcast.xml

```bash
git add appcast.xml
git commit -m "Update appcast.xml for v<VERSION>"
git push origin main
```

### 6. Report

Print a summary with:
- The GitHub release URL
- The tag name
- Confirmation that appcast.xml was pushed
