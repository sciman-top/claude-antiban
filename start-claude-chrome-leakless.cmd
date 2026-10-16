@echo off
setlocal
rem Opt-in variant of start-claude-chrome.cmd: same isolated profile, plus Chrome's
rem documented WebRTC IP handling policy (Chromium policy WebRtcIPHandling value
rem disable_non_proxied_udp, RFC 8828 section 5.2 mode 4 "force proxy"), so WebRTC
rem media cannot leave through non-proxied UDP while the browser uses a proxy.
rem It changes no locale, timezone, font, user agent, device ID or session data,
rem and gives no account-safety, eligibility or anti-detection guarantee.
rem Chrome ignores these switches when another instance already holds chrome-data:
rem close the browser completely before starting this entry.
set "browser=%ProgramFiles%\Google\Chrome\Application\chrome.exe"
if not exist "%browser%" set "browser=%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe"
if not exist "%browser%" (
  echo Chrome not found. Install from the official source or use your normal browser.
  exit /b 1
)
start "" "%browser%" --user-data-dir="%~dp0chrome-data" --no-first-run --force-webrtc-ip-handling-policy=disable_non_proxied_udp "https://claude.ai"
exit /b %errorlevel%
