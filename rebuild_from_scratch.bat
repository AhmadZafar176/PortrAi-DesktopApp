@echo off
echo ========================================
echo    FLUTTER APP REBUILD FROM SCRATCH
echo ========================================

echo Setting up environment...
set "PATH=C:\Program Files\Git\bin;C:\Program Files\Git\cmd;C:\Users\Maimona\Develop\flutter\bin;%PATH%"

echo Step 1: Cleaning all build artifacts...
flutter clean
if errorlevel 1 (
    echo ERROR: Flutter clean failed
    pause
    exit /b 1
)

echo Step 2: Removing .dart_tool directory...
if exist .dart_tool rmdir /s /q .dart_tool

echo Step 3: Removing build directory...
if exist build rmdir /s /q build

echo Step 4: Getting fresh dependencies...
flutter pub get
if errorlevel 1 (
    echo ERROR: Getting dependencies failed
    pause
    exit /b 1
)

echo Step 5: Building Windows app...
flutter build windows --release
if errorlevel 1 (
    echo ERROR: Build failed
    pause
    exit /b 1
)

echo ========================================
echo    BUILD COMPLETED SUCCESSFULLY!
echo ========================================
echo Build output location: build\windows\x64\runner\Release\
echo.
echo You can run the app using: build\windows\x64\runner\Release\portrai_flutter_app.exe
echo.
pause



