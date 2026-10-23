# Storage accounting and reclamation

The library exposes two different numbers for each machine:

- **On host:** allocated disk-image blocks, measured with `st_blocks × 512`.
- **Guest capacity:** the maximum logical disk size presented to the guest, in GiB.

Host allocation refreshes every **eight seconds while a VM is active**, even when the guest runs in its own app and the library is in the background. Start/stop, creation/deletion and reclamation also trigger refreshes. An image that cannot be inspected shows **usage unavailable**, and the combined total is unavailable until all images can be measured; failed measurements never appear as zero. The total covers disk images only. Firmware, guest tools, logs, installers, external runtimes and APFS snapshots/copy-on-write sharing have separate space costs. Image allocation is not a measurement of unique host-volume usage or free space inside the guest filesystem.

## Reclaim workflow

1. Delete unwanted files inside the guest.
2. Request guest TRIM: `sudo fstrim -av` in Linux, or **Optimize Drives → Optimize** in Windows. Support depends on the filesystem, guest driver and backend.
3. Shut down the VM. Pausing is not sufficient.
4. Choose **Reclaim disk space…** in its row menu, or **Virtual Machine → Reclaim Disk Space…**.

The scan reads allocated extents and deallocates complete host blocks only after verifying that all their bytes are zero. It does not interpret guest filesystem free-space maps, overwrite deleted files, change guest capacity or copy the disk. A runtime lease prevents a cooperating Lumen guest from starting or mutating that image during the scan. Native and QEMU guests hold this lease while running. Do not open the image in unrelated external tools during maintenance.

Progress is shown in the row, and **Cancel Disk Reclamation** stops further work while preserving bytes and completed block releases. Reclamation reports actual allocation before and after; a zero result explicitly says that no additional space was reclaimed. Unsupported host hole punching returns an error. Nonzero data left by deleted guest files cannot be reclaimed by this scan. APFS snapshots/clones or other copies may keep blocks alive even when image allocation decreases. Shrinking the guest disk and snapshot management remain separate, unimplemented operations.

## Disposable guest verification, October 23, 2026

Both tests used a fresh **512 MiB ext4 scratch disk**, a 128 MiB random file, a retained sentinel and read-only Void-compatible ARM64 live media. Networking and host folder shares were disabled. Host allocation was sampled after guest `sync` at every stage. No existing VM disk was opened or changed.

| Stage | QEMU + HVF, NVMe | Apple Virtualization, Virtio block |
| --- | ---: | ---: |
| Before file write | 25,722,880 bytes | 25,722,880 bytes |
| After 128 MiB write | 159,956,992 bytes | 159,940,608 bytes |
| After deleting the file | 159,956,992 bytes | 159,940,608 bytes |
| After `fstrim` | 25,669,632 bytes | 25,657,344 bytes |

Both guests accepted `fstrim`; allocation decreased by approximately **128 MiB** after trimming. Deleting the file alone did not reduce allocation. The disk capacity stayed **536,870,912 bytes** throughout, and the retained sentinel remained unchanged. `fstrim`'s printed trimmed range is not the same as actual host bytes recovered; the table uses measured disk-image allocation.

The QEMU test uses Lumen's raw image, `discard=unmap`, `detect-zeroes=unmap`, balanced cache and NVMe profile. The Apple test uses the same Virtio block attachment, automatic cache and fsync synchronization as the native engine. The host was macOS **27.0.1** on Apple Silicon. These results cover **Linux/ext4 on those two storage paths**. They do not validate Windows/NTFS, installed macOS guests, every Linux filesystem, other hosts or release-wide compatibility.

## Reproduce

```sh
brew install qemu sevenzip e2fsprogs
python3 scripts/validate-storage-trim.py \
  --iso /absolute/path/to/void-compatible-live-aarch64.iso \
  --output build/storage-trim-report.json
```

The script requires the live-media layout documented in its help. It creates exclusive temporary images, formats only those scratch images, boots headless QEMU and Apple VMs, samples all four stages, verifies the sentinel and removes the temporary guests/disks on completion or failure. JSON and console receipts remain at the selected output path. `--backend qemu` or `--backend apple` runs one path.

Core tests additionally verify byte-for-byte preservation, unchanged capacity/configuration, hard-link/symlink rejection, runtime-lease exclusion, cancellation before and after partial reclamation, already-sparse images and explicit zero-reclaimed results for nonzero data.
