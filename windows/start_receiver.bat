@echo off
REM ============================================================
REM  PocketTrackpad Windows 接收器 —— 一键启动（零安装）
REM
REM  本脚本只是用系统自带的 PowerShell 运行 pt_receiver.ps1，
REM  不需要安装 Python、不需要任何第三方依赖。
REM
REM  首次运行若 Windows 防火墙询问「是否允许此应用访问网络」，
REM  请选择「允许」，否则手机发来的数据包会被拦截。
REM ============================================================

setlocal
cd /d "%~dp0"

REM 系统自带 PowerShell，无需安装。
where powershell >nul 2>nul || (
    echo [错误] 没有找到 PowerShell（Windows 10/11 应自带）。
    pause
    exit /b 1
)

echo.
echo 正在启动 PocketTrackpad 接收器（UDP 5000，零安装）...
echo 提示：保持本窗口开着，用手机上的 App 连接。
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0pt_receiver.ps1" %*

echo.
echo 接收器已退出。
pause
