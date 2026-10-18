# 技术分析

[English](TECHNICAL.md) | [简体中文](TECHNICAL.zh-CN.md)

本文记录 `Start-HPCloudRecovery-Patched.ps1` 所依据的证据和具体补丁。

目标：**HP Cloud Recovery Tool 2.7.11.0 (x64)**，`CloudRecovery.exe`，SHA-256 `8870CC8AE9ECBAE9A2DE5D6591A12D92F932E6D8B4E0D7FAC28AD71847713E5E`。

该程序是原生 x64 MFC 应用（没有 CLR 头），不是 .NET 程序集。界面、WMI 访问、diskpart/PowerShell 封装和镜像处理全部是原生 C++。

---

## 1. 现象

使用 UASP 的 USB 3.x 闪存盘在 Windows 中报告为：

```text
Win32_DiskDrive
  InterfaceType : SCSI
  MediaType     : Removable Media
  Capabilities  : 3,4,7
  Size          : 61516869120
```

`Get-Disk` 仍然报告 `BusType = USB`：

```text
Number FriendlyName          BusType MediaType Size
------ --------------------- ------- --------- ----
     2 USB SanDisk 3.2Gen1   USB               61524148224
```

工具日志显示磁盘被枚举到了，随后又被过滤掉：

```text
DiskManager  >>> ScanDisks
DiskManager  <<< ScanDisks - disk count 3
AppLogicManager >>> GetRemovableUsbDiskList
AppLogicManager <<< GetRemovableUsbDiskList - 0
```

所以问题不是容量、文件系统，也不是 USB 代数，而是 `InterfaceType` 的值。

## 2. 过滤链

`GetRemovableUsbDiskList`（RVA `0x3FAC0`）创建 `DiskManager`，调用 `ScanDisks`，然后依次执行三个过滤器：

| 顺序 | 函数（RVA） | 作用 |
|---|---|---|
| 1 | `0x99420` | 只保留 `InterfaceType` 等于 `"usb"` 的磁盘（大小写不敏感） |
| 2 | `0x9C730` | 检查 `MediaType`；对 `fixed`/`external` 媒体再探测 TRIM，失败则移除 |
| 3 | `0x9C6C0` | 移除小于 `0x6C0000000` 字节（27 GiB）的磁盘 |

对 UASP 磁盘来说，卡在过滤器 1。原始代码：

```asm
140099440  mov  rcx, [rbx+30h]        ; Disk::interfaceType
140099444  lea  rdx, [1404F67A0h]     ; L"usb"
14009944B  call 1403FD5ACh            ; _wcsicmp
140099450  test eax, eax
140099452  jz   140099478h            ; 保留
140099454  ...                        ; 删除元素
```

`ScanDisks`（RVA `0x9C8B0`）从 `Win32_DiskDrive` 读取这些 WMI 属性：

```text
Capabilities, Caption, DeviceId, Index, InterfaceType,
MediaLoaded, MediaType, Partitions, Size, Status
```

`Disk` 对象大小为 0x78 字节。过滤器用到的字段：

| 偏移 | 字段 |
|---|---|
| `+0x00` | `std::vector<uint16_t>` capabilities |
| `+0x18` | Caption（宽字符串指针） |
| `+0x20` | DeviceID（宽字符串指针，`\\.\PHYSICALDRIVEn`） |
| `+0x28` | WMI 磁盘序号 |
| `+0x30` | InterfaceType（宽字符串指针） |
| `+0x60` | Size（uint64） |
| `+0x70` | MediaType（宽字符串指针） |

过滤器 2 用大小写敏感的 `wcsstr` 在 `MediaType` 中查找 `fixed` 和 `external`，然后通过 `IOCTL_STORAGE_QUERY_PROPERTY`（`StorageDeviceTrimProperty`）探测 TRIM。由于 WMI 返回的是 `Fixed hard disk media`（大写 `F`），小写查找通常匹配不到，所以过滤器 2 对大多数内置磁盘实际上不起作用。真正把内置磁盘挡在外面的只有过滤器 1。

## 3. 补丁

补丁把过滤器 1 换成 `MediaType` 检查：

```asm
140099440  48 8B 4B 70              mov  rcx, [rbx+70h]        ; Disk::mediaType
140099444  48 8D 15 <rel32>          lea  rdx, [分配的 L"Removable"]
14009944B  E8 78 A0 35 00           call 1403F34C8h            ; wcsstr
140099450  85 C0                    test eax, eax
140099452  75 24                    jnz  140099478h            ; 保留
```

为什么用 `MediaType`：

- UASP 闪存盘：`Removable Media` -> 保留
- USB BOT 闪存盘：`Removable Media` -> 保留
- 内置 NVMe/SATA：`Fixed hard disk media` -> 从候选列表移除
- USB 硬盘盒：`External hard disk media` -> 移除

`"Removable"` 字符串在目标进程内、模块附近分配（±2 GB 内），保证 RIP 相对 `LEA` 的 32 位有符号位移可用。`CALL wcsstr` 的位移是相对的，ASLR 重定位后仍然有效。

### 补丁字节

在 RVA `0x99440` 写入的 20 个字节：

```text
48 8B 4B 70
48 8D 15 <rel32>
E8 78 A0 35 00
85 C0
75 24
```

`rel32 = 分配的字符串地址 - (模块基址 + 0x9944B)`。

脚本写入后会读回 20 字节做校验。

## 4. 为什么不直接把 `"usb"` 改成 `"scsi"`

内置 NVMe 磁盘同样报告 `InterfaceType = SCSI`，并且支持 TRIM。过滤器 2 因为大小写问题通常不会移除它们。如果直接接受 `SCSI`，用户可能在这个会重新分区的工具里选中内置系统盘。`MediaType` 检查可以避免这个问题。

## 5. 为什么不直接改文件

程序是 `C:\Program Files\WindowsApps` 下的 MSIX 包，受 ACL 和包完整性保护。修改安装目录里的 EXE 需要：

- 从 TrustedInstaller 手里接管文件所有权；
- 破坏包签名；
- 被 Store 更新或修复覆盖；
- 回滚困难。

内存补丁关闭程序即失效，不触碰安装目录。

## 6. 版本与安全检查

脚本会：

1. 枚举 `%ProgramFiles%\WindowsApps` 下的 `AD2F1837.HPCloudRecoveryTool_*_x64__v10z8vjag6ke6`。
2. 对每个候选 `CloudRecovery\CloudRecovery.exe` 计算 SHA-256，必须与上面的值完全一致。
3. 如果已经运行的是其他 CloudRecovery 版本，拒绝操作。
4. 如果安装的不是受支持版本，拒绝打补丁。
5. 写入后读回校验。
6. 日志写入 `%TEMP%\HPCR-UASP-Patch.log`。

偏移和 `wcsstr` RVA 都是特定构建的。没有重新分析前，不要套用到其他版本。

## 7. 限制

- 补丁只改变磁盘枚举。它不解决“未在目录中找到下载的文件……”这类 catalog/下载问题。
- 恢复过程仍会格式化和重新分区所选 U 盘。请在下拉框中确认磁盘。
- 如果 HP 在未来版本修改过滤逻辑，哈希校验会拒绝补丁。
- 禁用 UASP（`UASPStor Start=4`）是不打补丁的替代方案，代价是 USB 3.x 吞吐量下降。

## 8. 复现步骤

1. 安装 HP Cloud Recovery Tool 2.7.11.0。
2. 确认 EXE 的 SHA-256。
3. 插入 UASP 闪存盘，在 `Win32_DiskDrive` 中观察 `InterfaceType = SCSI`。
4. 运行补丁脚本，用 `-VerifyOnly` 校验。
5. 打开 USB 准备页面，确认 U 盘出现。
6. 确认所选磁盘之前，不要开始恢复。

以上观察均来自本地测试环境。本仓库不包含任何序列号、服务标签、产品 ID 或用户标识。
