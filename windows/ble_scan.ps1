<#
    PocketTrackpad 蓝牙广播诊断（Windows 端零安装）

    用 Windows 自带的 PowerShell 调用 WinRT 蓝牙 API，扫描周围所有 BLE 广播，
    打印设备名、服务 UUID、原始 AD 数据。本机已装 Windows 10/11 即可运行，
    不装任何软件、不装驱动、不需要管理员权限。

    用途：确认 iPhone 是否在广播、广播里有没有 0x1812（HID 服务）与 Appearance。
    这正是 Windows「添加设备」列表能否看到本机的决定性因素。

    运行：
        右键此文件 →「使用 PowerShell 运行」
    或在 PowerShell 窗口里执行：
        powershell -NoProfile -ExecutionPolicy Bypass -File .\ble_scan.ps1
        powershell -NoProfile -ExecutionPolicy Bypass -File .\ble_scan.ps1 -Seconds 20

    参数：
        -Seconds 扫描时长（默认 15 秒）
        -Name    只显示名字包含该关键字的设备（默认不过滤）
#>

param(
    [int]$Seconds = 15,
    [string]$Name = ""
)

$ErrorActionPreference = 'Continue'

# WinRT 互操作需要 System.Runtime.WindowsRuntime 程序集。
# 优先用 LoadWithPartialName（不需要编译、不需要管理员），失败再退回 Add-Type。
if (-not ('System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions' -as [type])) {
    try {
        [void][System.Reflection.Assembly]::LoadWithPartialName('System.Runtime.WindowsRuntime')
    } catch {
        try { Add-Type -AssemblyName System.Runtime.WindowsRuntime } catch { }
    }
}

function ConvertFrom-Buffer {
    param($Buffer)
    if ($null -eq $Buffer) { return @() }
    try {
        return [System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions]::AsByteArray($Buffer)
    } catch {
        return @()
    }
}

# AD Type -> 名称
function Get-AdTypeName([int]$t) {
    switch ($t) {
        0x01 { 'Flags' }
        0x02 { 'Incomplete 16-bit UUIDs' }
        0x03 { 'Complete 16-bit UUIDs' }
        0x04 { 'Incomplete 32-bit UUIDs' }
        0x05 { 'Complete 32-bit UUIDs' }
        0x06 { 'Incomplete 128-bit UUIDs' }
        0x07 { 'Complete 128-bit UUIDs' }
        0x08 { 'Shortened Local Name' }
        0x09 { 'Complete Local Name' }
        0x0A { 'TX Power Level' }
        0x16 { 'Service Data 16-bit' }
        0x19 { 'Appearance' }
        0x1C { 'Service Data' }
        0xFF { 'Manufacturer Data' }
        default { "AD 0x{0:X2}" -f $t }
    }
}

Write-Host ''
Write-Host '==============================================' -ForegroundColor Cyan
Write-Host ' BLE 广播扫描（PocketTrackpad 诊断）' -ForegroundColor Cyan
Write-Host '==============================================' -ForegroundColor Cyan
Write-Host ("扫描 {0} 秒，请保持 iPhone 上的 App 在前台运行。" -f $Seconds)
Write-Host ''

try {
    $watcherType = [Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
} catch {
    Write-Host "无法加载蓝牙 WinRT 接口：本机可能不支持 BLE 或系统版本过低。" -ForegroundColor Red
    exit 1
}

$watcher = New-Object Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher
$watcher.ScanningMode = [Windows.Devices.Bluetooth.Advertisement.BluetoothLEScanningMode]::Active

$seen = @{}

$handler = Register-ObjectEvent -InputObject $watcher -EventName Received -Action {
    $args = $Event.SourceEventArgs
    $adv = $args.Advertisement
    $key = if ($adv.LocalName) { $adv.LocalName } else { $args.BluetoothAddress.ToString() }

    if ($script:seen.ContainsKey($key)) { return }

    $uuids = @()
    if ($adv.ServiceUuids) { $uuids = @($adv.ServiceUuids | ForEach-Object { $_.ToString() }) }

    $script:seen[$key] = $true

    Write-Host ''
    Write-Host ('-' * 50) -ForegroundColor DarkGray
    Write-Host ("设备名    : {0}" -f $(if ($adv.LocalName) { $adv.LocalName } else { '(无名称)' }))
    Write-Host ("地址      : {0}" -f $args.BluetoothAddress.ToString())
    Write-Host ("信号      : {0} dBm" -f $args.RawSignalStrengthInDBm)
    Write-Host ("广播类型  : {0}" -f $args.BluetoothAdvertisementType)
    Write-Host ("服务 UUID : {0}" -f $(if ($uuids.Count) { $uuids -join ', ' } else { '(无)' }))

    $raw = ''
    try {
        foreach ($sec in $adv.RawData.Sections) {
            $bytes = ConvertFrom-Buffer $sec.Data
            $hex = ($bytes | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
            $raw += ('{0}: {1}' -f (Get-AdTypeName $sec.DataType), $hex) + "`r`n"
            if ($sec.DataType -eq 0x19 -and $bytes.Count -ge 2) {
                $app = $bytes[0] + ($bytes[1] -shl 8)
                Write-Host ("Appearance : 0x{0:X4}  ({1})" -f $app, $(switch ($app) {
                    0x03C1 { 'HID Keyboard' }
                    0x03C2 { 'HID Mouse' }
                    0x03C0 { 'Generic HID' }
                    0x0001 { 'Generic' }
                    default { '其他' }
                })) -ForegroundColor Green
            }
        }
    } catch { }

    if ($raw) {
        Write-Host '原始广播数据：' -ForegroundColor DarkGray
        Write-Host $raw -ForegroundColor DarkGray
    }
}

$watcher.Start()
Write-Host '扫描中……' -ForegroundColor Yellow

$end = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $end) { Start-Sleep -Milliseconds 300 }

$watcher.Stop()
Unregister-Event -SourceIdentifier $handler.Name -ErrorAction SilentlyContinue
Remove-Job -Id $handler.Id -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host '==============================================' -ForegroundColor Cyan
Write-Host ("扫描结束，共发现 {0} 个 BLE 设备。" -f $seen.Count)
Write-Host '==============================================' -ForegroundColor Cyan

if ($Name -ne '') {
    Write-Host ''
    Write-Host ("名字包含「{0}」的设备：" -f $Name) -ForegroundColor Cyan
    $hit = $seen.Keys | Where-Object { $_ -like "*$Name*" }
    if ($hit) { $hit | ForEach-Object { Write-Host ("  -> {0}" -f $_) -ForegroundColor Green } }
    else { Write-Host '  （未发现）' -ForegroundColor Yellow }
}

Write-Host ''
Write-Host 'Windows 侧下一步：设置 → 设备 → 蓝牙和其他设备 → 添加设备 → 其他蓝牙设备。'
Write-Host '若列表里看不到，点「显示所有设备」（Win11 24H2+）'
Write-Host '或把「设置 → 设备 → 设备设置 → 蓝牙设备发现」改成「高级」（Win11 22H2/23H2）。'
Write-Host ''
