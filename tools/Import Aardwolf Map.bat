@echo off
rem Windows launcher — double-click. The work is in import-map.py, which is the
rem same on every platform. 'py' is the launcher installed with Python on
rem Windows; python is the fallback for a PATH install.
cd /d "%~dp0"

where py >nul 2>&1 && (
    py -3 import-map.py
    goto :eof
)

where python >nul 2>&1 && (
    python import-map.py
    goto :eof
)

echo.
echo   Python 3 isn't installed.
echo   Get it from https://www.python.org/downloads/ and tick
echo   "Add Python to PATH" during setup.
echo.
pause
