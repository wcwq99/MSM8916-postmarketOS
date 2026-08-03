@echo off
setlocal enabledelayedexpansion
title MSM8916 postmarketOS Fastboot Flasher

REM ===========================================================================
REM MSM8916 postmarketOS multi-board image fastboot flasher.
REM
REM Mirrors the one-click style of the Rongyue E5 SPD flasher, but targets
REM Qualcomm MSM8916 devices running in lk1st/aboot fastboot mode.
REM
REM Prerequisites:
REM   - fastboot.exe on PATH or in .\bin\
REM   - Release tarball unpacked next to this script so that the following
REM     relative paths resolve:
REM         .\bootloaders\hyp.mbn
REM         .\bootloaders\tz.mbn
REM         .\bootloaders\aboot-thwc-ufi001c.mbn
REM         .\bootloaders\aboot-thwc-uf896.mbn
REM         .\bootloaders\aboot-yiming-uz801v3.mbn
REM         .\export\zhihe-generic-boot.img
REM         .\export\zhihe-generic-root.img
REM
REM Safety:
REM   - Bootloader (hyp/tz/aboot) flashing can hard-brick the device. Keep EDL
REM     backup and recovery tools ready before proceeding.
REM   - Upstream warns against mixing DragonBoard tz with stock hyp. Only flash
REM     the bundled tz/hyp pair together.
REM   - lk1st only auto-detects UFI001C, UF896, UZ801 V3. Pick the closest
REM     variant for other boards.
REM ===========================================================================

set "SCRIPT_DIR=%~dp0"
set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

set "BL_DIR=%SCRIPT_DIR%\bootloaders"
set "EXPORT_DIR=%SCRIPT_DIR%\export"

REM fastboot.exe may live in .\bin\ (portable) or on PATH.
set "FASTBOOT="
if exist "%SCRIPT_DIR%\bin\fastboot.exe" (
    set "FASTBOOT=%SCRIPT_DIR%\bin\fastboot.exe"
) else (
    where fastboot.exe >nul 2>&1 && for /f "delims=" %%i in ('where fastboot.exe') do set "FASTBOOT=%%i"
)
if not defined FASTBOOT (
    echo ERROR: fastboot.exe not found.
    echo Put it in .\bin\fastboot.exe or install Android platform-tools on PATH.
    goto :abort
)

REM ---- Pre-flight: verify release artifacts exist before waiting for device --
set "MISSING="
for %%F in (
    "%BL_DIR%\hyp.mbn"
    "%BL_DIR%\tz.mbn"
    "%BL_DIR%\aboot-thwc-ufi001c.mbn"
    "%BL_DIR%\aboot-thwc-uf896.mbn"
    "%BL_DIR%\aboot-yiming-uz801v3.mbn"
    "%EXPORT_DIR%\zhihe-generic-boot.img"
    "%EXPORT_DIR%\zhihe-generic-root.img"
) do (
    if not exist %%F set "MISSING=!MISSING!    %%~F"
)
if defined MISSING (
    echo ERROR: Required release artifacts not found:
    echo !MISSING!
    echo.
    echo Unpack postmarketos-msm8916-multiboard.tar.gz next to this script first.
    goto :abort
)

echo.
echo ============================================================
echo  MSM8916 postmarketOS Fastboot Flasher
echo ============================================================
echo.
echo  WARNING: Flashing bootloader ^(hyp/tz/aboot^) can HARD-BRICK
echo  the device. Make sure you have:
echo    - A full EDL backup of this device
echo    - Recovery tools and a second device for testing
echo    - Read the postmarketOS Zhihe series wiki page
echo.
echo  Upstream warns: do NOT mix DragonBoard tz with stock hyp.
echo  Only flash the bundled tz+hyp pair together.
echo.
echo  Default account: user / 147147  ^(change after first boot^)
echo.
echo ============================================================
echo.
echo  Flash scope:
echo    [1] Bootloader + boot + root  ^(highest risk, full flash^)
echo    [2] Boot + root only          ^(recommended, keeps stock bootloader^)
echo    [3] Boot only                 ^(kernel/DTB swap^)
echo.
set /p "SCOPE=Select flash scope [1-3] (default 2): "
if "!SCOPE!"=="" set "SCOPE=2"
if "!SCOPE!"=="1" goto :scope_ok
if "!SCOPE!"=="2" goto :scope_ok
if "!SCOPE!"=="3" goto :scope_ok
echo Invalid scope: !SCOPE!
goto :abort

:scope_ok
set "FLASH_BOOTLOADER=0"
set "FLASH_BOOT=0"
set "FLASH_ROOT=0"
if "!SCOPE!"=="1" (
    set "FLASH_BOOTLOADER=1"
    set "FLASH_BOOT=1"
    set "FLASH_ROOT=1"
)
if "!SCOPE!"=="2" (
    set "FLASH_BOOT=1"
    set "FLASH_ROOT=1"
)
if "!SCOPE!"=="3" set "FLASH_BOOT=1"

set "ABOOT_FILE="
if "!FLASH_BOOTLOADER!"=="1" (
    echo.
    echo  lk1st only auto-detects these boards:
    echo    [1] thwc-ufi001c      ^(UFI001C, default^)
    echo    [2] thwc-uf896        ^(UF896^)
    echo    [3] yiming-uz801v3    ^(UZ801 V3^)
    echo.
    echo  For other boards keep the stock bootloader, or pick the closest
    echo  variant after confirming hardware compatibility.
    echo.
    set /p "ABOOT=Select aboot variant [1-3] (default 1): "
    if "!ABOOT!"=="" set "ABOOT=1"
    if "!ABOOT!"=="1" set "ABOOT_FILE=%BL_DIR%\aboot-thwc-ufi001c.mbn"
    if "!ABOOT!"=="2" set "ABOOT_FILE=%BL_DIR%\aboot-thwc-uf896.mbn"
    if "!ABOOT!"=="3" set "ABOOT_FILE=%BL_DIR%\aboot-yiming-uz801v3.mbn"
    if not defined ABOOT_FILE (
        echo Invalid aboot variant: !ABOOT!
        goto :abort
    )
    echo.
    echo  You are about to flash:
    echo    hyp.mbn
    echo    tz.mbn
    echo    !ABOOT_FILE!
    echo.
    echo  Type YES ^(uppercase^) to confirm bootloader flash.
    set /p "CONFIRM_BL=Confirm: "
    if not "!CONFIRM_BL!"=="YES" (
        echo Bootloader flash cancelled.
        goto :abort
    )
)

echo.
echo ============================================================
echo  Step 1/4: Waiting for fastboot device
echo  ^(Boot device into fastboot mode now: hold Vol-Down + Power, or
echo   run "adb reboot bootloader" if USB debug is on.^)
echo ============================================================

set "TIMEOUT=300"
set /a "ELAPSED=0"
:wait_device
"%FASTBOOT%" devices 2>nul | findstr /R "^.*fastboot$" >nul
if !errorlevel! equ 0 goto :device_ready
set /a "ELAPSED+=2"
if !ELAPSED! geq !TIMEOUT! (
    echo ERROR: No fastboot device after !TIMEOUT! seconds.
    goto :abort
)
echo   waiting... !ELAPSED!s / !TIMEOUT!s
REM 2-second polling interval; avoids burning CPU on a tight loop.
timeout /t 2 /nobreak >nul
goto :wait_device

:device_ready
echo   device detected:
"%FASTBOOT%" devices

REM Boot partition on MSM8916 lk1st is always "boot" (non-A/B device).
set "BOOT_PART=boot"
REM Userdata holds the btrfs root image; cache is wiped separately by -w.
set "ROOT_TARGET=userdata"

REM ---- On A/B devices, mark the just-flashed slot active so we boot from it.
REM lk1st reports current-slot as "_a"/"_b" (with underscore) or "a"/"b".
REM Strip any non-alphanumeric chars before passing back to --set-active.
set "ACTIVE_SLOT="
for /f "tokens=2 delims= " %%a in ('"%FASTBOOT%" getvar current-slot 2^>nul') do (
    set "RAW_SLOT=%%a"
)
if defined RAW_SLOT (
    set "ACTIVE_SLOT=!RAW_SLOT!"
    set "ACTIVE_SLOT=!ACTIVE_SLOT: =!"
)

if "!FLASH_BOOTLOADER!"=="1" (
    echo.
    echo ============================================================
    echo  Step 2/4: Flashing bootloader  ^(high risk^)
    echo ============================================================
    REM Order matters: hyp and tz are a matched pair from DragonBoard
   REM 410c linux bootloader bundle. Flash them together, never mix with stock.
    "%FASTBOOT%" flash hyp "%BL_DIR%\hyp.mbn"
    if !errorlevel! neq 0 goto :flash_failed
    "%FASTBOOT%" flash tz "%BL_DIR%\tz.mbn"
    if !errorlevel! neq 0 goto :flash_failed
    REM aboot/lk1st goes to the aboot partition on MSM8916; some lk1st builds
    REM also expose it as "sbl1" -- keep aboot as the canonical name.
    "%FASTBOOT%" flash aboot "!ABOOT_FILE!"
    if !errorlevel! neq 0 goto :flash_failed
    echo   bootloader flashed: hyp, tz, !ABOOT_FILE!
) else (
    echo.
    echo  Step 2/4: Skipping bootloader ^(scope !SCOPE!^)
)

if "!FLASH_BOOT!"=="1" (
    echo.
    echo ============================================================
    echo  Step 3/4: Flashing boot image
    echo ============================================================
    "%FASTBOOT%" flash !BOOT_PART! "%EXPORT_DIR%\zhihe-generic-boot.img"
    if !errorlevel! neq 0 goto :flash_failed
    echo   boot flashed to !BOOT_PART!
) else (
    echo.
    echo  Step 3/4: Skipping boot ^(scope !SCOPE!^)
)

if "!FLASH_ROOT!"=="1" (
    echo.
    echo ============================================================
    echo  Step 4/4: Flashing root image
    echo ============================================================
    REM zhihe-generic-root.img is a btrfs raw image. fastboot accepts raw
    REM images on userdata, but on smaller bootloaders a sparse image is more
    REM reliable. Use "fastboot flash -S" auto-splitting as a fallback if the
    REM raw flash fails. The postmarketOS wiki suggests userdata or system as
    REM the destination; userdata is safest because it is never needed for boot.
    echo   target partition: !ROOT_TARGET!
    echo   ^(if userdata flash fails, try "system" manually after this script^)
    "%FASTBOOT%" flash !ROOT_TARGET! "%EXPORT_DIR%\zhihe-generic-root.img"
    if !errorlevel! neq 0 (
        echo   raw flash returned !errorlevel!, retrying with -S 256M auto-split...
        "%FASTBOOT%" flash -S 256M !ROOT_TARGET! "%EXPORT_DIR%\zhihe-generic-root.img"
        if !errorlevel! neq 0 goto :flash_failed
    )
    echo   root flashed to !ROOT_TARGET!
) else (
    echo.
    echo  Step 4/4: Skipping root ^(scope !SCOPE!^)
)

REM ---- On A/B devices, mark the just-flashed slot active so we boot from it -
if defined ACTIVE_SLOT (
    if not "!ACTIVE_SLOT!"=="" (
        "%FASTBOOT%" --set-active="!ACTIVE_SLOT!" 2>nul
    )
)

echo.
echo ============================================================
echo  Wiping cache and userdata ^(as appropriate^)
echo ============================================================
REM Conditional wipe to avoid clobbering the rootfs we just wrote:
REM  - If we flashed root to userdata, only erase cache.
REM  - Otherwise, erase both userdata and cache to clear stale Android data.
"%FASTBOOT%" erase cache 2>nul
if "!FLASH_ROOT!"=="1" (
    echo   userdata skipped ^(just flashed with root image^)
) else (
    "%FASTBOOT%" erase userdata 2>nul
)

echo.
echo ============================================================
echo  Rebooting device
echo ============================================================
"%FASTBOOT%" reboot

echo.
echo ============================================================
echo  Done.
echo  First boot may take a few minutes. Default login: user / 147147.
echo  Change the password immediately after first login.
echo ============================================================
echo.
pause
exit /b 0

:flash_failed
echo.
echo ERROR: fastboot flash failed ^(last command exit !errorlevel!^).
echo Device may be in an inconsistent state. Do NOT reboot yet.
echo Check fastboot output above and the postmarketOS Zhihe wiki for recovery.
echo.
pause
exit /b 1

:abort
echo.
echo Aborted. No changes were written to the device.
echo.
pause
exit /b 1
