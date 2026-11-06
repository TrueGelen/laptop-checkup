@echo off
rem Full check (~35 min): info, battery, SSD, CPU, GPU, CPU+GPU. Report goes to reports\ on this drive.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0checkup.ps1" -Mode Full
