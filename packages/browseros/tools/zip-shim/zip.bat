@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0zip-shim.ps1" %*
exit /b %ERRORLEVEL%
