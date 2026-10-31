disk space visualizer and storage management utility designed for macOS. It helps users quickly identify what is consuming space on their hard drives, solid-state drives (SSDs), or external storage media.

By converting complex file structures into interactive visual maps (such as treemaps or sunburst diagrams), it simplifies the process of finding large, unused, or hidden files and folders that clog up system storage.

---

## 2. Key Features

* **Interactive Storage Visualizations:** Displays files and directories as proportional blocks or segments, making large files instantly recognizable.
* **Fast Storage Scanning:** Built to quickly index local drives, external drives, network attached storage (NAS), and mounted images.
* **In-App File Cleanup:** Allows users to preview, move to Trash, or permanently delete unwanted files directly from the application interface.
* **System & User Space Filtering:** Helps separate user files (photos, videos, downloads) from system files to prevent accidental deletion of critical system assets.
* **Finder Integration:** Quick shortcuts to reveal selected files directly inside macOS Finder.
* **Support for macOS System Features:** Native support for Dark Mode, Apple Silicon (M1/M2/M3/M4 chips), and macOS file system permissions.

---

## 3. How it Works

1. **Scanning:** it scans the selected volume or folder using macOS file system APIs.
2. **Indexing & Sizing:** It calculates the total allocated size of every directory and child file.
3. **Rendering:** It translates these metrics into a visual layout where **Block Area = File/Folder Size**.
4. **Navigation:** Users can click into subdirectories to "drill down" into specific folders or navigate backward to get a high-level view of the entire disk.

---

## 4. Primary Use Cases

* **Recovering Free Space:** Finding massive, forgotten files like old video renders, disk images (`.dmg`), virtual machine disks (`.vmdk`/`.qcow2`), or bloated cache folders.
* **Managing Media Libraries:** Identifying duplicate or excessively large media files (4K footage, high-res audio).
* **System Maintenance:** Locating hidden caches located in `~/Library/Caches` or remnant files from uninstalled applications.
* **External Drive Auditing:** Quickly assessing the contents of backup drives or external SSDs without browsing through hundreds of subfolders manually.

---

## 5. Common Alternatives on macOS

If you are evaluating it alongside other macOS storage utilities, here are the primary alternatives in the same category:

| Tool | Visual Style | Best Known For |
| :--- | :--- | :--- |
| **DaisyDisk** | Sunburst / Radial Chart | Sleek design, high performance |
| **GrandPerspective** | Treemap Grid | Free/Open Source, classic Unix style |
| **OmniDiskSweeper** | Column List View | Minimalist, fast text-based breakdown |
| **CleanMyMac** | Dashboards & Lists | All-in-one system cleaning suite |

---

## 6. Best Practices & Safety Tips

1. **Grant Full Disk Access:** For DiskUnbloat to scan all directories accurately (including `~/Library`), ensure it is granted *Full Disk Access* in **System Settings > Privacy & Security > Full Disk Access**.
2. **Be Cautious with System Files:** Avoid deleting files inside `/System`, `/Library`, or system-managed user hidden directories unless you are sure of their purpose.
3. **Use the Trash First:** Instead of using immediate permanent deletion, move files to the macOS Trash so they can be restored if needed.