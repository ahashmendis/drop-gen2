@echo off
setlocal
set "D=%LOCALAPPDATA%\Drop"
echo Installing Drop to %D% ...
if not exist "%D%" mkdir "%D%"
copy /Y "%~dp0Drop.ps1" "%D%\Drop.ps1" >nul
copy /Y "%~dp0Drop.ico" "%D%\Drop.ico" >nul
rem Shared code (Drop.ps1 dot-sources DropCore.ps1, which loads the others) - all must sit beside Drop.ps1.
for %%F in (DropCore.ps1 DropOop.ps1 DropAcd.ps1 DropAcdValidate.ps1 DropAcdRun.ps1 DropBench.ps1) do copy /Y "%~dp0%%F" "%D%\%%F" >nul
rem ACD lecture notes and benchmark sample tasks (from this folder or the repo root). Drop copies them into %APPDATA%\Drop
rem on start WITHOUT overwriting anything you edited there.
for %%S in (acd-notes bench-tasks) do (
  if exist "%~dp0%%S" xcopy /E /I /Y /Q "%~dp0%%S" "%D%\%%S\" >nul
  if exist "%~dp0..\%%S" xcopy /E /I /Y /Q "%~dp0..\%%S" "%D%\%%S\" >nul
)
rem Quiet laptop: drop Ollama's login auto-start (best-effort; only its own
rem HKCU Run value - other startup entries are left alone).
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v Ollama /f >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem -LiteralPath '%D%' -Recurse -File | Unblock-File; $s = New-Object -ComObject WScript.Shell; $l = $s.CreateShortcut([Environment]::GetFolderPath('Programs') + '\Drop.lnk'); $l.TargetPath = 'powershell.exe'; $l.Arguments = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File \"%D%\Drop.ps1\"'; $l.IconLocation = '%D%\Drop.ico'; $l.WindowStyle = 7; $l.Save()"
echo.
echo Done. Starting Drop...
start "" "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Drop.lnk"
echo.
echo Open it any time: Start menu ^> Drop, the tray icon, or Ctrl+Alt+D.
pause
