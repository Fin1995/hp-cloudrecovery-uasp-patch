# HP Cloud Recovery Tool - UASP / SCSI USB patch

[简体中文](README.md) | [English](README.en.md)

A small, memory-only patch for **HP Cloud Recovery Tool 2.7.11.0 (x64)** that makes the tool recognize USB flash drives which enumerate as **SCSI** because they use **UASP** (USB Attached SCSI Protocol).

No file under `C:\Program Files\WindowsApps` is modified. The patch lives in the running process only; closing the app removes it.

> Not affiliated with HP Inc. Use at your own risk. The recovery process will erase the selected USB drive.

---

## The problem

HP Cloud Recovery Tool only lists disks whose `Win32_DiskDrive.InterfaceType` is `USB`:

```text
GetRemovableUsbDiskList
  -> filter InterfaceType == "usb"
  -> filter media type
  -> filter size >= 27 GiB
```

Many USB 3.x flash drives use UASP and report:

```text
InterfaceType : SCSI
MediaType     : Removable Media
Capabilities  : 3,4,7
```

The drive is present in Windows and visible in Explorer, but the tool's drop-down says **"No USB flash drive connected"**. The tool's log confirms the drive is scanned and then filtered out:

```text
ScanDisks - disk count 3
GetRemovableUsbDiskList - 0
```

This is not a capacity problem and not a "USB 3.2 Gen 1 is too new" problem. It is the `InterfaceType` check.

## Before / after

The screenshots use the Chinese UI. The test drive is a SanDisk 3.2Gen1 64 GB USB flash drive.

| Before | After |
|---|---|
| ![Before: the drive is not listed](docs/images/before.png) | ![After: the drive is listed](docs/images/after.png) |

## How the patch works

The patcher changes the first filter in the running process from:

```asm
; original
mov  rcx, [rbx+30h]        ; Disk::interfaceType
lea  rdx, [L"usb"]
call _wcsicmp
test eax, eax
jz   keep
```

to:

```asm
; patched
mov  rcx, [rbx+70h]        ; Disk::mediaType
lea  rdx, [L"Removable"]
call wcsstr
test eax, eax
jnz  keep
```

Result:

| Disk | MediaType | Listed? |
|---|---|---|
| USB flash drive (UASP, SCSI) | `Removable Media` | **Yes** |
| USB flash drive (BOT, USB) | `Removable Media` | **Yes** |
| Internal NVMe / SATA SSD | `Fixed hard disk media` | No |
| USB HDD enclosure | `External hard disk media` | No |

The rest of the tool is untouched: disk selection, `diskpart`, partition creation, image extraction and verification use the original code.

## Supported build

| Item | Value |
|---|---|
| App | HP Cloud Recovery Tool |
| Version | `2.7.11.0` |
| Architecture | x64 |
| SHA-256 of `CloudRecovery.exe` | `8870CC8AE9ECBAE9A2DE5D6591A12D92F932E6D8B4E0D7FAC28AD71847713E5E` |

The script refuses to patch any other build. HP may change the filter or the offsets in a future version; do not bypass the check.

## Quick start

1. Plug in the USB drive.
2. Double-click **`Start-HPCloudRecovery-Patched.cmd`**.
3. Approve the UAC prompt.
4. The script launches HP Cloud Recovery Tool and patches it.
5. Use the tool normally. The drive should appear in the drop-down.

The first launch shows the EULA and asks for the HP product ID; that part is unchanged.

### Console language

Terminal messages support Chinese and English. Chinese is the default (`-Language zh`). Use `-Language auto` to follow the Windows region (Chinese on Chinese systems, English otherwise), or `-Language en` for English; the `.cmd` launcher passes arguments through.

```powershell
.\Start-HPCloudRecovery-Patched.cmd -Language en
powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-HPCloudRecovery-Patched.ps1 -Language auto
```

### Verify only

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-HPCloudRecovery-Patched.ps1 -VerifyOnly
```

Exit code `0` means the running process is patched (or the supported build is installed but the app is not running).

### Patch an already-running app

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-HPCloudRecovery-Patched.ps1 -NoLaunch
```

## Requirements

- Windows 10/11 x64
- 64-bit PowerShell 5.1 or later
- Administrator rights (the tool itself needs admin to format disks)
- HP Cloud Recovery Tool 2.7.11.0 installed from the Microsoft Store

## Safety and limitations

- **Memory-only.** No installed file is modified, no signature is touched, no driver is installed.
- **Version-locked.** The script verifies the SHA-256 of `CloudRecovery.exe` before patching.
- **Internal disks stay hidden.** The new filter accepts `Removable Media`; internal NVMe/SATA disks report `Fixed hard disk media`.
- **Still verify the drive.** The selected USB drive will be erased and repartitioned. Confirm the drive letter, model and size in the drop-down before clicking Next.
- **Not a download/catalog fix.** If the tool reports "No download file is found by catalog..." that is a separate catalog/cache problem.
- **App updates.** If the Store updates the app, the script will refuse to patch until the offsets and hash are updated.

## Alternative without patching

If you prefer not to patch the app, disable UASP so the drive enumerates as USB:

```reg
HKLM\SYSTEM\CurrentControlSet\Services\UASPStor\Start = 4
```

Reboot, create the recovery media, then set it back to `3` and reboot again. A USB 2.0 port or a USB 2.0 hub also forces the drive to use the BOT protocol.

Trade-off: disabling UASP affects all USB 3.x storage and reduces throughput.

## Technical write-up

See [docs/TECHNICAL.md](docs/TECHNICAL.md) for the WMI evidence, the decompiled filter functions and the exact patch bytes.

## Files

```text
Start-HPCloudRecovery-Patched.cmd   self-elevating launcher
Start-HPCloudRecovery-Patched.ps1   patcher / verifier
README.md                           Chinese documentation (default)
README.en.md                        English documentation
docs/TECHNICAL.md                   English technical notes
docs/TECHNICAL.zh-CN.md             Chinese technical notes
docs/images/before.png              before screenshot
docs/images/after.png               after screenshot
CHANGELOG.md                        Chinese release history
CHANGELOG.en.md                     English release history
.gitignore                          local artifacts / screenshots
LICENSE                             MIT
```

## Legal

This project contains no HP code or binaries and is not affiliated with HP Inc. It is an interoperability fix for disk enumeration. You are responsible for complying with the HP software license that applies to your copy of HP Cloud Recovery Tool. Do not use it to bypass licensing or to create recovery media you are not entitled to.

## License

MIT. See [LICENSE](LICENSE).

HP, HP Cloud Recovery Tool and OMEN are trademarks of HP Inc. This project is an independent interoperability fix and is not endorsed by HP.
