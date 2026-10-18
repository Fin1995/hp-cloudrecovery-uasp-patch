#Requires -Version 5.1
<#
    HP Cloud Recovery Tool 2.7.11.0 - UASP / SCSI USB patch
    -------------------------------------------------------
    The stock tool only accepts disks whose Win32_DiskDrive
    InterfaceType is "USB".  USB 3.x flash drives that use UASP
    (USB Attached SCSI Protocol) report InterfaceType "SCSI", so
    the tool silently filters them out and shows
    "No USB flash drive connected".

    This script patches the running process in memory so the
    disk filter accepts disks whose MediaType contains
    "Removable" instead.  Internal NVMe/SATA disks report
    "Fixed hard disk media" and remain excluded.

    Nothing on disk is modified.  Closing the app removes the
    patch.  Run this script (as administrator) instead of the
    normal app shortcut.

    Supported build:
        HP Cloud Recovery Tool 2.7.11.0 (x64)
        SHA-256 8870CC8AE9ECBAE9A2DE5D6591A12D92F932E6D8B4E0D7FAC28AD71847713E5E

    License: MIT.  Not affiliated with HP Inc.
#>

[CmdletBinding()]
param(
    [switch]$NoLaunch,
    [switch]$VerifyOnly,
    [ValidateSet('auto', 'zh', 'en')]
    [string]$Language = 'zh'
)

$ErrorActionPreference = 'Stop'

try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

if ($Language -eq 'auto') {
    $culture = [System.Globalization.CultureInfo]::CurrentCulture
    $script:UiLanguage = if ($culture.TwoLetterISOLanguageName -eq 'zh') { 'zh' } else { 'en' }
} else {
    $script:UiLanguage = $Language
}

function T([string]$Chinese, [string]$English) {
    if ($script:UiLanguage -eq 'zh') { return $Chinese }
    return $English
}

# ---------------------------------------------------------------
# Constants for HP Cloud Recovery Tool 2.7.11.0 (x64)
# ---------------------------------------------------------------
$ExpectedSha256  = '8870CC8AE9ECBAE9A2DE5D6591A12D92F932E6D8B4E0D7FAC28AD71847713E5E'
$ExpectedVersion = '2.7.11.0'
$PackageFamily   = 'AD2F1837.HPCloudRecoveryTool_v10z8vjag6ke6'
$Aumid           = "$PackageFamily!App"
$PackageDirGlob  = 'AD2F1837.HPCloudRecoveryTool_*_x64__v10z8vjag6ke6'
$ExeRelativePath = 'CloudRecovery\CloudRecovery.exe'

# File offsets (RVA) for 2.7.11.0
$PatchRva   = 0x99440   # FUN_140099420: InterfaceType=="usb" filter
$LeaNextRva = 0x9944B   # address after the LEA RDX,[...] instruction
# The CALL target (wcsstr at RVA 0x3F34C8) is encoded as a relative
# displacement, so it stays valid when the image is relocated.

$LogPath = Join-Path $env:TEMP 'HPCR-UASP-Patch.log'

# ---------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------
function Write-Log([string]$Level, [string]$Message) {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
    switch ($Level) {
        'INFO'  { Write-Host "[*] $Message" -ForegroundColor Cyan }
        'OK'    { Write-Host "[+] $Message" -ForegroundColor Green }
        'WARN'  { Write-Host "[!] $Message" -ForegroundColor Yellow }
        'ERROR' { Write-Host "[-] $Message" -ForegroundColor Red }
    }
}

function Fail([string]$Message) {
    Write-Log 'ERROR' $Message
    exit 1
}

# ---------------------------------------------------------------
# Self-elevate and require 64-bit PowerShell
# ---------------------------------------------------------------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
    if ($NoLaunch)   { $argList += '-NoLaunch' }
    if ($VerifyOnly) { $argList += '-VerifyOnly' }
    $argList += '-Language'
    $argList += $Language
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    exit
}

if (-not [Environment]::Is64BitProcess) {
    Fail (T '此脚本必须在 64 位 PowerShell 中运行, 因为目标程序是 x64.' 'This script must run in 64-bit PowerShell because the target app is x64.')
}

Write-Log 'INFO' (T 'HP Cloud Recovery Tool 2.7.11.0 UASP 补丁' 'HP Cloud Recovery Tool 2.7.11.0 UASP patch')
Write-Log 'INFO' (T "日志文件: $LogPath" "Log file: $LogPath")

# ---------------------------------------------------------------
# Locate the supported installed build
# ---------------------------------------------------------------
$programFiles = [Environment]::GetFolderPath('ProgramFiles')
$windowsApps  = Join-Path $programFiles 'WindowsApps'

if (-not (Test-Path -LiteralPath $windowsApps)) {
    Fail (T "未找到 WindowsApps 目录: $windowsApps" "WindowsApps directory not found: $windowsApps")
}

$candidates = @()
try {
    $candidates = @(Get-ChildItem -LiteralPath $windowsApps -Directory -Filter $PackageDirGlob -ErrorAction Stop)
} catch {
    Fail (T "无法枚举 $windowsApps.请以管理员身份运行脚本.$($_.Exception.Message)" "Could not enumerate $windowsApps. Run the script as administrator. $($_.Exception.Message)")
}

if ($candidates.Count -eq 0) {
    Fail (T "未安装 HP Cloud Recovery Tool ($ExpectedVersion).支持的包: $PackageDirGlob" "HP Cloud Recovery Tool ($ExpectedVersion) is not installed. Supported package: $PackageDirGlob")
}

$ExePath = $null
$found = @()
foreach ($dir in $candidates) {
    $exe = Join-Path $dir.FullName $ExeRelativePath
    if (-not (Test-Path -LiteralPath $exe)) { continue }

    $hash = $null
    try { $hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash } catch { }
    $ver  = $null
    try { $ver = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion } catch { }

    $found += [pscustomobject]@{ Path = $exe; Version = $ver; Sha256 = $hash }

    if ($hash -eq $ExpectedSha256) {
        $ExePath = $exe
        break
    }
}

if (-not $ExePath) {
    Write-Log 'ERROR' (T '没有安装与受支持 SHA-256 匹配的版本.' 'No installed build matches the supported SHA-256.')
    foreach ($f in $found) {
        Write-Log 'ERROR' (T ("找到: {0}  版本={1}  sha256={2}" -f $f.Path, $f.Version, $f.Sha256) ("Found: {0}  version={1}  sha256={2}" -f $f.Path, $f.Version, $f.Sha256))
    }
    Fail (T '补丁偏移与版本相关.请为已安装版本更新脚本, 或安装 2.7.11.0.' 'The patch offsets are version-specific. Update the script for the installed build or install 2.7.11.0.')
}

Write-Log 'INFO' (T "受支持版本: $ExePath" "Supported build: $ExePath")
Write-Log 'INFO' (T "SHA-256: $ExpectedSha256" "SHA-256: $ExpectedSha256")

# ---------------------------------------------------------------
# P/Invoke
# ---------------------------------------------------------------
if (-not ('HPCRPatch' -as [type])) {
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class HPCRPatch {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool ReadProcessMemory(IntPtr h, IntPtr addr, byte[] buf, int size, out IntPtr read);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool WriteProcessMemory(IntPtr h, IntPtr addr, byte[] buf, int size, out IntPtr written);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool VirtualProtectEx(IntPtr h, IntPtr addr, UIntPtr size, uint newProtect, out uint oldProtect);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr VirtualAllocEx(IntPtr h, IntPtr addr, UIntPtr size, uint allocType, uint protect);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool VirtualFreeEx(IntPtr h, IntPtr addr, UIntPtr size, uint freeType);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool FlushInstructionCache(IntPtr h, IntPtr addr, UIntPtr size);
}
"@
}

function Read-Bytes([IntPtr]$h, [long]$addr, [int]$len) {
    $buf  = New-Object byte[] $len
    $read = [IntPtr]::Zero
    if (-not [HPCRPatch]::ReadProcessMemory($h, [IntPtr]$addr, $buf, $len, [ref]$read)) {
        throw (T ("ReadProcessMemory 失败, 地址 0x{0:X}: {1}" -f $addr, [Runtime.InteropServices.Marshal]::GetLastWin32Error()) ("ReadProcessMemory failed at 0x{0:X}: {1}" -f $addr, [Runtime.InteropServices.Marshal]::GetLastWin32Error()))
    }
    return $buf
}

function Write-Bytes([IntPtr]$h, [long]$addr, [byte[]]$bytes) {
    $old  = [uint32]0
    $size = [UIntPtr]::new([uint64]$bytes.Length)
    if (-not [HPCRPatch]::VirtualProtectEx($h, [IntPtr]$addr, $size, 0x40, [ref]$old)) {
        throw (T ("VirtualProtectEx 失败, 地址 0x{0:X}: {1}" -f $addr, [Runtime.InteropServices.Marshal]::GetLastWin32Error()) ("VirtualProtectEx failed at 0x{0:X}: {1}" -f $addr, [Runtime.InteropServices.Marshal]::GetLastWin32Error()))
    }
    $written = [IntPtr]::Zero
    $ok  = [HPCRPatch]::WriteProcessMemory($h, [IntPtr]$addr, $bytes, $bytes.Length, [ref]$written)
    $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    $old2 = [uint32]0
    [void][HPCRPatch]::VirtualProtectEx($h, [IntPtr]$addr, $size, $old, [ref]$old2)
    if (-not $ok) {
        throw (T ("WriteProcessMemory 失败, 地址 0x{0:X}: {1}" -f $addr, $err) ("WriteProcessMemory failed at 0x{0:X}: {1}" -f $addr, $err))
    }
    [void][HPCRPatch]::FlushInstructionCache($h, [IntPtr]$addr, $size)
}

# ---------------------------------------------------------------
# Find or launch the app
# ---------------------------------------------------------------
$all = @(Get-Process -Name 'CloudRecovery' -ErrorAction SilentlyContinue)
$matching = @()
foreach ($p in $all) {
    try {
        if ($p.Path -eq $ExePath) { $matching += $p }
    } catch { }
}

if ($all.Count -gt 0 -and $matching.Count -eq 0) {
    $paths = @()
    foreach ($p in $all) {
        try { $paths += $p.Path } catch { $paths += '<unknown>' }
    }
    Fail (T ("已有另一个 CloudRecovery 版本在运行: {0}.请关闭它后重新运行此启动器." -f ($paths -join '; ')) ("A different CloudRecovery build is already running: {0}. Close it and run this launcher again." -f ($paths -join '; ')))
}

$proc = $matching | Select-Object -First 1

if ($VerifyOnly -and -not $proc) {
    Write-Log 'OK' (T '找到受支持版本, 但程序未运行.' 'Supported build found, but the app is not running.')
    exit 0
}

if (-not $proc -and -not $NoLaunch) {
    Write-Log 'INFO' (T '正在启动 HP Cloud Recovery Tool...' 'Launching HP Cloud Recovery Tool...')
    Start-Process "shell:AppsFolder\$Aumid"

    $deadline = (Get-Date).AddSeconds(40)
    do {
        Start-Sleep -Milliseconds 500
        $all = @(Get-Process -Name 'CloudRecovery' -ErrorAction SilentlyContinue)
        foreach ($p in $all) {
            try {
                if ($p.Path -eq $ExePath) { $proc = $p; break }
            } catch { }
        }
    } while (-not $proc -and (Get-Date) -lt $deadline)
}

if (-not $proc) {
    if ($VerifyOnly) {
        Write-Log 'OK' (T '找到受支持版本, 但程序未运行.' 'Supported build found, but the app is not running.')
        exit 0
    }
    Fail (T 'CloudRecovery.exe 未运行.请启动程序后重新运行此脚本.' 'CloudRecovery.exe is not running. Launch the app and run this script again.')
}

$proc.Refresh()
$base = $proc.MainModule.BaseAddress.ToInt64()
Write-Log 'INFO' (T ("PID {0}, 模块基址 0x{1:X}" -f $proc.Id, $base) ("PID {0}, module base 0x{1:X}" -f $proc.Id, $base))

$h = [HPCRPatch]::OpenProcess(0x1F0FFF, $false, $proc.Id)
if ($h -eq [IntPtr]::Zero) {
    Fail (T ("OpenProcess 失败: {0}" -f [Runtime.InteropServices.Marshal]::GetLastWin32Error()) ("OpenProcess failed: {0}" -f [Runtime.InteropServices.Marshal]::GetLastWin32Error()))
}

try {
    $patchAddr = $base + $PatchRva
    $current   = Read-Bytes $h $patchAddr 20

    # -----------------------------------------------------------
    # Already patched?
    # -----------------------------------------------------------
    $already = $false
    if ($current[0] -eq 0x48 -and $current[1] -eq 0x8B -and $current[2] -eq 0x4B -and $current[3] -eq 0x70) {
        $rel = [int32]([int]$current[7] -bor ([int]$current[8] -shl 8) -bor ([int]$current[9] -shl 16) -bor ([int]$current[10] -shl 24))
        $strAddr = $patchAddr + 11 + $rel
        try {
            $s = Read-Bytes $h $strAddr 20
            $text = [Text.Encoding]::Unicode.GetString($s)
            if ($text.StartsWith('Removable')) { $already = $true }
        } catch { }
    }

    if ($already) {
        Write-Log 'OK' (T ("已经打过补丁 (PID {0}), 无需操作." -f $proc.Id) ("Already patched (PID {0}). Nothing to do." -f $proc.Id))
        exit 0
    }

    if ($VerifyOnly) {
        Fail (T '正在运行的进程尚未打补丁.' 'The running process is not patched.')
    }

    # -----------------------------------------------------------
    # Allocate the "Removable" string near the module.
    # The LEA RIP-relative displacement must fit in signed 32 bits.
    # -----------------------------------------------------------
    $strBytes = [Text.Encoding]::Unicode.GetBytes("Removable`0")
    $mem = [IntPtr]::Zero
    foreach ($off in 0x01000000, 0x02000000, 0x04000000, 0x08000000,
                     0x10000000, 0x20000000, 0x30000000, 0x40000000,
                     0x50000000, 0x60000000, 0x70000000) {
        $cand = [IntPtr]($base + $off)
        $m = [HPCRPatch]::VirtualAllocEx($h, $cand, [UIntPtr]::new(64), 0x3000, 0x04)
        if ($m -ne [IntPtr]::Zero) { $mem = $m; break }
    }
    if ($mem -eq [IntPtr]::Zero) {
        Fail (T '无法在模块附近为过滤字符串分配内存.' 'Could not allocate memory near the module for the filter string.')
    }

    $written = [IntPtr]::Zero
    if (-not [HPCRPatch]::WriteProcessMemory($h, $mem, $strBytes, $strBytes.Length, [ref]$written)) {
        Fail (T ("WriteProcessMemory (字符串)失败: {0}" -f [Runtime.InteropServices.Marshal]::GetLastWin32Error()) ("WriteProcessMemory (string) failed: {0}" -f [Runtime.InteropServices.Marshal]::GetLastWin32Error()))
    }

    $rel = [int64]$mem.ToInt64() - ($base + $LeaNextRva)
    if ($rel -lt [int32]::MinValue -or $rel -gt [int32]::MaxValue) {
        Fail (T '分配到的字符串超出了 +/-2 GB 的 RIP 相对寻址范围.' 'Allocated string is outside the +/-2 GB RIP-relative range.')
    }

    $seq = New-Object byte[] 20
    # MOV RCX,[RBX+0x70]        ; Disk::mediaType
    $seq[0] = 0x48; $seq[1] = 0x8B; $seq[2] = 0x4B; $seq[3] = 0x70
    # LEA RDX,[allocated "Removable"]
    $seq[4] = 0x48; $seq[5] = 0x8D; $seq[6] = 0x15
    $seq[7]  = [byte]($rel -band 0xFF)
    $seq[8]  = [byte](($rel -shr 8) -band 0xFF)
    $seq[9]  = [byte](($rel -shr 16) -band 0xFF)
    $seq[10] = [byte](($rel -shr 24) -band 0xFF)
    # CALL wcsstr (RVA 0x3F34C8; rel32 = 0x35A078)
    $seq[11] = 0xE8; $seq[12] = 0x78; $seq[13] = 0xA0; $seq[14] = 0x35; $seq[15] = 0x00
    # TEST EAX,EAX ; JNZ keep (0x140099478)
    $seq[16] = 0x85; $seq[17] = 0xC0; $seq[18] = 0x75; $seq[19] = 0x24

    Write-Bytes $h $patchAddr $seq

    $verify = Read-Bytes $h $patchAddr 20
    $ok = $true
    for ($i = 0; $i -lt 20; $i++) {
        if ($seq[$i] -ne $verify[$i]) { $ok = $false; break }
    }
    if (-not $ok) {
        Fail (T '补丁校验失败.' 'Patch verification failed.')
    }

    Write-Log 'OK' (T ("已修补 PID {0}.USB 列表现在接受 Removable Media 磁盘." -f $proc.Id) ("Patched PID {0}. The USB list now accepts Removable Media disks." -f $proc.Id))
    Write-Log 'OK' (T '现在可以正常使用 HP Cloud Recovery Tool.' 'You can now use the HP Cloud Recovery Tool normally.')
    Write-Log 'INFO' (T '补丁只存在于内存中; 关闭程序后即失效.' 'The patch is memory-only; closing the app removes it.')
}
finally {
    [void][HPCRPatch]::CloseHandle($h)
}
