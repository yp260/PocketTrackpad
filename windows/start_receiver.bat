@echo off
REM ============================================================
REM  PocketTrackpad Windows 接收器 —— 一键启动
REM  双击本文件即可，无需管理员权限，无需第三方依赖。
REM
REM  首次运行若 Windows 防火墙询问「是否允许 Python 访问网络」，
REM  请务必选择「允许」，否则手机发来的数据包会被拦截。
REM ============================================================

setlocal
cd /d "%~dp0"

REM 优先用 py -3（Python Launcher），退回 python
set "PY="
where py >nul 2>nul && set "PY=py -3"
if not defined PY (
    where python >nul 2>nul && set "PY=python"
)

if not defined PY (
    echo.
    echo [错误] 没有找到 Python。
    echo 请先安装 Python 3.8 或更新版本： https://www.python.org/downloads/
    echo 安装时务必勾选 "Add python.exe to PATH"。
    echo.
    pause
    exit /b 1
)

echo.
echo 正在启动 PocketTrackpad 接收器（UDP 5000）...
echo 提示：保持本窗口开着，用手机上的 App 连接。
echo.
echo %PY% pt_receiver.py %*

echo.
echo 接收器已退出。
pause
