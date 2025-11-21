@echo off
set PATH=C:\Program Files\Git\bin;C:\Program Files\Git\cmd;%PATH%
flutter clean
flutter pub get
flutter build windows
echo Build completed!
pause
