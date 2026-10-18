# Technical notes

[English](TECHNICAL.md) | [简体中文](TECHNICAL.zh-CN.md)

This document describes the evidence and the exact patch used by `Start-HPCloudRecovery-Patched.ps1`.

Target: **HP Cloud Recovery Tool 2.7.11.0 (x64)**, `CloudRecovery.exe`, SHA-256 `8870CC8AE9ECBAE9A2DE5D6591A12D92F932E6D8B4E0D7FAC28AD71847713E5E`.

The binary is a native x64 MFC application (no CLR header), not a .NET assembly. The UI, WMI access, diskpart/PowerShell wrappers and image handling are all native C++.

---

## 1. Symptom

With a USB 3.x flash drive that uses UASP, Windows reports:

```text
Win32_DiskDrive
  InterfaceType : SCSI
  MediaType     : Removable Media
  Capabilities  : 3,4,7
  Size          : 61516869120
```

`Get-Disk` still reports `BusType = USB`:

```text
Number FriendlyName          BusType MediaType Size
------ --------------------- ------- --------- ----
     2 USB SanDisk 3.2Gen1   USB               61524148224
```

The tool's log shows that the drive is enumerated and then filtered out:

```text
DiskManager  >>> ScanDisks
DiskManager  <<< ScanDisks - disk count 3
AppLogicManager >>> GetRemovableUsbDiskList
AppLogicManager <<< GetRemovableUsbDiskList - 0
```

So the problem is not capacity, file system, or the USB generation. It is the `InterfaceType` value.

## 2. Filter chain

`GetRemovableUsbDiskList` (RVA `0x3FAC0`) creates a `DiskManager`, calls `ScanDisks`, then applies three filters in order:

| Order | Function (RVA) | Effect |
|---|---|---|
| 1 | `0x99420` | Keep only disks whose `InterfaceType` equals `"usb"` (case-insensitive) |
| 2 | `0x9C730` | Inspect `MediaType`; remove `fixed`/`external` media unless a TRIM probe succeeds |
| 3 | `0x9C6C0` | Remove disks smaller than `0x6C0000000` bytes (27 GiB) |

Filter 1 is the blocker for UASP drives. Its original code is:

```asm
140099440  mov  rcx, [rbx+30h]        ; Disk::interfaceType
140099444  lea  rdx, [1404F67A0h]     ; L"usb"
14009944B  call 1403FD5ACh            ; _wcsicmp
140099450  test eax, eax
140099452  jz   140099478h            ; keep
140099454  ...                        ; erase element
```

`ScanDisks` (RVA `0x9C8B0`) reads these WMI properties from `Win32_DiskDrive`:

```text
Capabilities, Caption, DeviceId, Index, InterfaceType,
MediaLoaded, MediaType, Partitions, Size, Status
```

The `Disk` object is 0x78 bytes. The relevant fields used by the filters are:

| Offset | Field |
|---|---|
| `+0x00` | `std::vector<uint16_t>` capabilities |
| `+0x18` | Caption (wide string pointer) |
| `+0x20` | DeviceID (wide string pointer, `\\.\PHYSICALDRIVEn`) |
| `+0x28` | WMI disk index |
| `+0x30` | InterfaceType (wide string pointer) |
| `+0x60` | Size (uint64) |
| `+0x70` | MediaType (wide string pointer) |

Filter 2 searches `MediaType` for `fixed` and `external` with a case-sensitive `wcsstr` and then probes TRIM via `IOCTL_STORAGE_QUERY_PROPERTY` (`StorageDeviceTrimProperty`). Because WMI returns `Fixed hard disk media` with a capital `F`, the lowercase search usually does not match; filter 2 is effectively a no-op for most internal disks. Filter 1 is therefore the only thing keeping internal disks out of the list.

## 3. Patch

The patch replaces filter 1 with a `MediaType` check:

```asm
140099440  48 8B 4B 70              mov  rcx, [rbx+70h]        ; Disk::mediaType
140099444  48 8D 15 <rel32>          lea  rdx, [allocated L"Removable"]
14009944B  E8 78 A0 35 00           call 1403F34C8h            ; wcsstr
140099450  85 C0                    test eax, eax
140099452  75 24                    jnz  140099478h            ; keep
```

Why `MediaType`:

- UASP flash drive: `Removable Media` -> kept.
- USB BOT flash drive: `Removable Media` -> kept.
- Internal NVMe/SATA: `Fixed hard disk media` -> erased from the candidate list.
- USB HDD enclosure: `External hard disk media` -> erased.

The `"Removable"` string is allocated in the target process near the module (within +/-2 GB) so the RIP-relative `LEA` displacement fits in a signed 32-bit value. The `CALL wcsstr` displacement is relative and remains valid when the image is relocated by ASLR.

### Patch bytes

The 20 bytes written at RVA `0x99440` are:

```text
48 8B 4B 70
48 8D 15 <rel32>
E8 78 A0 35 00
85 C0
75 24
```

`rel32 = allocated_string_address - (module_base + 0x9944B)`.

The script verifies the write by reading the 20 bytes back.

## 4. Why not simply accept `SCSI`?

Changing the comparison string from `"usb"` to `"scsi"` would also accept internal NVMe disks, which report `InterfaceType = SCSI` and support TRIM. Filter 2 would not remove them because of the case-sensitive `fixed` search. That could let a user select an internal system disk in a tool that repartitions the target. The `MediaType` check avoids that.

## 5. Why not patch the file?

The app is an MSIX package under `C:\Program Files\WindowsApps`, protected by ACLs and package integrity. Editing the installed EXE would:

- require taking ownership from TrustedInstaller;
- invalidate the package signature;
- be overwritten or repaired by the Store;
- make rollback harder.

The memory patch is reversible by closing the app and does not touch the installation.

## 6. Versioning and safety checks

The script:

1. Enumerates `AD2F1837.HPCloudRecoveryTool_*_x64__v10z8vjag6ke6` under `%ProgramFiles%\WindowsApps`.
2. Hashes each candidate `CloudRecovery\CloudRecovery.exe` and requires the exact SHA-256 above.
3. Refuses to run if a different CloudRecovery build is already running.
4. Refuses to patch if the build is not the supported one.
5. Verifies the patched bytes after writing.
6. Logs to `%TEMP%\HPCR-UASP-Patch.log`.

The offsets and the `wcsstr` RVA are build-specific. Do not reuse them for another version without re-analysis.

## 7. Limitations

- The patch only changes disk enumeration. It does not fix catalog/download errors such as "No download file is found by catalog...".
- The recovery process still formats and repartitions the selected USB drive. Confirm the drive in the drop-down.
- If HP changes the filter in a future build, the hash check will reject the patch.
- Disabling UASP (`UASPStor Start=4`) is a no-patch alternative, at the cost of USB 3.x throughput.

## 8. Reproduction checklist

1. Install HP Cloud Recovery Tool 2.7.11.0.
2. Confirm the EXE SHA-256.
3. Attach a UASP flash drive and observe `InterfaceType = SCSI` in `Win32_DiskDrive`.
4. Run the patcher and verify with `-VerifyOnly`.
5. Open the USB preparation page and confirm the drive appears.
6. Do not start the recovery until the selected drive is confirmed.

All observations above were made on a local test system. No serial numbers, service tags, product IDs or user identifiers are included in this repository.
