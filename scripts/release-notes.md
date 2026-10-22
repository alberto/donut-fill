A DaisyDisk-style disk usage analyzer for macOS: scan a disk or folder and explore it as a sunburst chart, then gather what you want to delete in the Collector.

**Requirements:** macOS 14 or later, Apple Silicon Mac.

### Installing

1. Download `Donut-Fill-{{VERSION}}.zip`, unzip it and move **Donut Fill** to Applications.
2. The app isn't notarized by Apple, so the first time you open it macOS says it can't check it for malicious software. Go to **System Settings → Privacy & Security** and click **Open Anyway**.
   Or, in Terminal: `xattr -dr com.apple.quarantine "/Applications/Donut Fill.app"`
3. For complete results, grant it **Full Disk Access** in System Settings → Privacy & Security. Without it, folders it can't read are counted as hidden space.


