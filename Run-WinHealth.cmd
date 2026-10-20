@echo off
rem Double-click launcher. Runs WinHealth with a one-off execution policy
rem bypass (nothing is changed system-wide); the script asks for admin rights.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0WinHealth.ps1" %*
