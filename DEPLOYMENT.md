# Windows Deployment Guide

This guide provides step-by-step instructions for deploying the PortrAI Flutter app on Windows systems.

## Prerequisites

### Development Machine (macOS)
- Flutter SDK 3.24.5+
- Xcode (for iOS simulator testing)
- Android Studio (for Android testing)

### Target Windows Machine
- Windows 10 version 1903 or later
- 64-bit architecture
- 4GB RAM minimum
- 500MB free disk space

## Building for Windows

### Step 1: Prepare Windows Development Environment

On a Windows machine:

1. **Install Flutter**
   ```bash
   # Download Flutter SDK for Windows from:
   # https://docs.flutter.dev/get-started/install/windows
   
   # Extract to C:\flutter
   # Add C:\flutter\bin to system PATH
   ```

2. **Install Visual Studio**
   - Download Visual Studio 2019 or later
   - Install with "Desktop development with C++" workload
   - Include Windows 10/11 SDK

3. **Enable Windows Desktop Support**
   ```bash
   flutter config --enable-windows-desktop
   flutter doctor
   ```

### Step 2: Build the Application

1. **Clone and Setup**
   ```bash
   git clone <repository-url>
   cd portrai_flutter_app
   flutter pub get
   ```

2. **Configure Firebase**
   - Update `lib/services/firebase_config.dart` with your Firebase settings
   - Update Firebase options in `main.dart`

3. **Build Release Version**
   ```bash
   # Debug build
   flutter build windows --debug
   
   # Release build (recommended for deployment)
   flutter build windows --release
   ```

### Step 3: Package for Distribution

The built application will be in `build/windows/runner/Release/`:

```
Release/
├── portrai_flutter_app.exe
├── flutter_windows.dll
├── data/
│   ├── flutter_assets/
│   └── icudtl.dat
└── [other dependencies]
```

## Deployment Options

### Option 1: Direct Distribution

1. **Create Distribution Package**
   ```bash
   # Create a zip file with the Release folder
   zip -r portrai_app_windows.zip build/windows/runner/Release/
   ```

2. **Deploy to Target Machines**
   - Copy the zip file to target Windows machines
   - Extract to desired location (e.g., `C:\Program Files\PortrAI\`)
   - Create desktop shortcut to `portrai_flutter_app.exe`

### Option 2: MSI Installer (Advanced)

1. **Install WiX Toolset**
   ```bash
   # Download and install WiX Toolset
   # https://wixtoolset.org/
   ```

2. **Create WiX Configuration**
   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <Wix xmlns="http://schemas.microsoft.com/wix/2006/wi">
     <Product Id="*" Name="PortrAI" Language="1033" Version="1.0.0.0" 
              Manufacturer="Your Company" UpgradeCode="PUT-GUID-HERE">
       <Package InstallerVersion="200" Compressed="yes" InstallScope="perMachine" />
       
       <MajorUpgrade DowngradeErrorMessage="A newer version is already installed." />
       <MediaTemplate />
       
       <Feature Id="ProductFeature" Title="PortrAI" Level="1">
         <ComponentGroupRef Id="ProductComponents" />
       </Feature>
     </Product>
     
     <Fragment>
       <Directory Id="TARGETDIR" Name="SourceDir">
         <Directory Id="ProgramFilesFolder">
           <Directory Id="INSTALLFOLDER" Name="PortrAI" />
         </Directory>
       </Directory>
     </Fragment>
     
     <Fragment>
       <ComponentGroup Id="ProductComponents" Directory="INSTALLFOLDER">
         <Component Id="MainExecutable" Guid="*">
           <File Id="PortrAIExe" Name="portrai_flutter_app.exe" 
                 Source="build/windows/runner/Release/portrai_flutter_app.exe" />
         </Component>
       </ComponentGroup>
     </Fragment>
   </Wix>
   ```

3. **Build MSI**
   ```bash
   candle portrai.wxs
   light portrai.wixobj
   ```

### Option 3: Windows Store (Future)

For Microsoft Store distribution:
1. Create Windows Store developer account
2. Package as MSIX
3. Submit through Partner Center

## Configuration

### Firebase Setup

1. **Create Firebase Project**
   - Go to [Firebase Console](https://console.firebase.google.com/)
   - Create new project: "PortrAI"
   - Enable Authentication, Firestore, Storage

2. **Configure Authentication**
   ```
   Authentication > Sign-in method > Email/Password > Enable
   ```

3. **Configure Firestore**
   ```
   Firestore Database > Create database > Production mode
   ```

4. **Configure Storage**
   ```
   Storage > Get started > Production mode
   ```

5. **Update App Configuration**
   ```dart
   // lib/services/firebase_config.dart
   static const String apiKey = "YOUR_API_KEY";
   static const String authDomain = "your-project.firebaseapp.com";
   static const String projectId = "your-project-id";
   // ... other configuration
   ```

### Security Rules

**Firestore Rules:**
```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /users/{userId}/{document=**} {
      allow read, write: if request.auth != null && request.auth.uid == userId;
    }
  }
}
```

**Storage Rules:**
```javascript
rules_version = '2';
service firebase.storage {
  match /b/{bucket}/o {
    match /users/{userId}/{allPaths=**} {
      allow read, write: if request.auth != null && request.auth.uid == userId;
    }
  }
}
```

## Installation on Target Machines

### System Requirements

- **OS**: Windows 10 version 1903 or later
- **Architecture**: x64
- **RAM**: 4GB minimum, 8GB recommended
- **Storage**: 500MB free space
- **Network**: Internet connection for Firebase

### Installation Steps

1. **Download Application**
   - Download the distribution package
   - Extract to desired location

2. **Install Dependencies**
   - Visual C++ Redistributable (if not already installed)
   - Windows 10/11 SDK (if needed)

3. **Run Application**
   - Double-click `portrai_flutter_app.exe`
   - First run may take longer to initialize

4. **Create Desktop Shortcut**
   - Right-click on `portrai_flutter_app.exe`
   - Select "Create shortcut"
   - Move shortcut to Desktop

## Troubleshooting

### Common Issues

1. **Application Won't Start**
   - Check Windows version compatibility
   - Install Visual C++ Redistributable
   - Run as administrator

2. **Firebase Connection Issues**
   - Verify internet connection
   - Check firewall settings
   - Verify Firebase configuration

3. **Performance Issues**
   - Close other applications
   - Check available RAM
   - Update graphics drivers

4. **Build Issues**
   ```bash
   # Clean and rebuild
   flutter clean
   flutter pub get
   flutter build windows --release
   ```

### Debug Mode

For troubleshooting, run in debug mode:
```bash
flutter run -d windows
```

This provides:
- Console output
- Error messages
- Performance metrics
- Hot reload for development

## Updates and Maintenance

### Updating the Application

1. **Build New Version**
   ```bash
   flutter build windows --release
   ```

2. **Deploy Updates**
   - Replace executable files
   - Update data files if needed
   - Test on target machines

### Monitoring

- Check Firebase Console for usage statistics
- Monitor error logs
- Track user authentication
- Review Firestore usage

## Security Considerations

1. **Firebase Security**
   - Use proper Firestore security rules
   - Enable Firebase App Check
   - Monitor authentication logs

2. **Application Security**
   - Keep Flutter SDK updated
   - Use secure storage for sensitive data
   - Implement proper error handling

3. **Network Security**
   - Use HTTPS for all communications
   - Validate all user inputs
   - Implement rate limiting

## Support and Maintenance

### Log Files

Application logs are stored in:
- Windows Event Viewer
- Firebase Console
- Application console output

### Performance Monitoring

- Monitor Firebase usage quotas
- Track application performance
- Review user feedback

### Backup Strategy

- Firebase data is automatically backed up
- Consider local backup of user configurations
- Implement data export functionality

## Conclusion

This deployment guide provides comprehensive instructions for building, packaging, and deploying the PortrAI Flutter application on Windows systems. The application maintains full compatibility with the legacy Python version while providing a modern, cross-platform solution.

For additional support or questions, refer to the main README.md file or contact the development team.


