@echo off
setlocal
rem Ordinary isolated profile; inherits the browser's normal network configuration.
rem No fingerprint, language or timezone spoofing; no account safety guarantee.
set "browser=%ProgramFiles%\Google\Chrome\Application\chrome.exe"
if not exist "%browser%" set "browser=%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe"
if not exist "%browser%" (
  echo Chrome not found. Install from the official source or use your normal browser.
  exit /b 1
)
start "" "%browser%" --user-data-dir="%~dp0chrome-data" --no-first-run "https://claude.ai"
exit /b %errorlevel%
