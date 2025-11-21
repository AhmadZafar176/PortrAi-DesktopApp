@echo off
echo Setting up environment...
set PATH=C:\Program Files\Git\bin;C:\Program Files\Git\cmd;C:\Users\Maimona\Develop\flutter\bin;%PATH%

echo Cleaning previous build...
C:\Users\Maimona\Develop\flutter\bin\flutter.bat clean

echo Getting dependencies...
C:\Users\Maimona\Develop\flutter\bin\flutter.bat pub get

echo Building Windows app...
C:\Users\Maimona\Develop\flutter\bin\flutter.bat build windows

echo Build completed!
pause
