## Install

1. Download **Panescroll-vX.Y.Z.zip** below, unzip it, and move **Panescroll.app** to **Applications**.
2. Panescroll isn't notarized by Apple yet, so the first time you open it macOS says it can't check the app for malware. To open it anyway:
   - Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to Panescroll, **or**
   - run `xattr -dr com.apple.quarantine /Applications/Panescroll.app` in Terminal, then open it normally.
3. When asked, turn on Panescroll in **System Settings → Privacy & Security → Accessibility**. Tiling starts right away.

Requires macOS 14 Sonoma or later. Runs natively on Apple silicon and Intel.

**Updating:** this build is ad-hoc signed, so after replacing the app with a new version, remove Panescroll from the Accessibility list and turn it on again.

You can also build from source; see the [README](https://github.com/Kiran-Alex/panescroll#build-from-source). Check the download against the `.sha256` file with `shasum -a 256 Panescroll-*.zip`.
