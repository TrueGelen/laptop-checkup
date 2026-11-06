@echo off
rem Re-run cleanup for the latest run (if the window was closed in the middle of a test).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0checkup.ps1" -CleanupOnly
