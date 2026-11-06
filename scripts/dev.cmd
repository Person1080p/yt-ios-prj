@echo off
rem Windows entry point for scripts/dev.sh: runs the ytp server and Vite inside WSL.
rem   scripts\dev.cmd        (from cmd or PowerShell; Git Bash can run scripts/dev.sh directly)
rem Mounts the project's drive in WSL if needed (mapped network drives aren't auto-mounted),
rem installs the toolchain on first run (scripts/setup-wsl.sh), then starts dev.sh.
rem Open http://localhost:5173 in your Windows browser; stop with Ctrl-C.
setlocal

where wsl.exe >nul 2>&1 || (
  echo error: WSL is not installed. Run "wsl --install -d Ubuntu" in an admin terminal, reboot, then try again. 1>&2
  exit /b 1
)

for %%I in ("%~dp0..") do set "root=%%~fI"
if "%root:~0,2%"=="\\" (
  echo error: run this from a drive letter, not a UNC path - map the share to a drive first. 1>&2
  exit /b 1
)

rem Z:\Coding\yt-prj -> /mnt/z/Coding/yt-prj
set "letter=%root:~0,1%"
for %%L in (a b c d e f g h i j k l m n o p q r s t u v w x y z) do if /i "%letter%"=="%%L" set "letter=%%L"
set "rest=%root:~2%"
set "wslroot=/mnt/%letter%%rest:\=/%"

for /f %%u in ('wsl.exe --cd ~ -e id -u') do set "uid=%%u"
for /f %%g in ('wsl.exe --cd ~ -e id -g') do set "gid=%%g"
if not defined uid (
  echo error: couldn't start WSL - check "wsl --status". 1>&2
  exit /b 1
)

wsl.exe -u root --cd ~ -e sh -c "mountpoint -q /mnt/%letter% || { mkdir -p /mnt/%letter% && mount -t drvfs %letter%: /mnt/%letter% -o uid=%uid%,gid=%gid%; }" || (
  echo error: couldn't mount %letter%: in WSL. 1>&2
  exit /b 1
)

wsl.exe -u root --cd ~ -e bash "%wslroot%/scripts/setup-wsl.sh" system || exit /b 1
wsl.exe --cd ~ -e bash "%wslroot%/scripts/setup-wsl.sh" user || exit /b 1

wsl.exe --cd "%wslroot%" -e bash scripts/dev.sh
exit /b %errorlevel%
