@echo off
setlocal
set "D=%LOCALAPPDATA%\Drop"
echo Installing Drop to %D% ...
if not exist "%D%" mkdir "%D%"
copy /Y "%~dp0Drop.ps1" "%D%\Drop.ps1" >nul
copy /Y "%~dp0Drop.ico" "%D%\Drop.ico" >nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "Unblock-File -LiteralPath '%D%\Drop.ps1'; $s = New-Object -ComObject WScript.Shell; $l = $s.CreateShortcut([Environment]::GetFolderPath('Programs') + '\Drop.lnk'); $l.TargetPath = 'powershell.exe'; $l.Arguments = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File \"%D%\Drop.ps1\"'; $l.IconLocation = '%D%\Drop.ico'; $l.WindowStyle = 7; $l.Save()"
echo.
echo Done. Starting Drop...
start "" "%APPDATA%\Microsoft\Windows\Start Menu\Programs\Drop.lnk"
echo.
echo Open it any time: Start menu ^> Drop, the tray icon, or Ctrl+Alt+D.
pause
