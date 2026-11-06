@echo off
rem Quick smoke run (~6 min): same steps with short durations, to check that everything works.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0checkup.ps1" -Mode Quick
