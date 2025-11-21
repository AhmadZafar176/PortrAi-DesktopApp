@echo off
echo Setting up environment...
set PATH=C:\Program Files\Git\bin;C:\Program Files\Git\cmd;C:\Users\Maimona\Develop\flutter\bin;%PATH%

echo Getting dependencies...
flutter pub get

echo Building Windows app...
flutter build windows

echo Build completed!
pause





