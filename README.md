# PortrAI Flutter App

A Flutter application that replicates the functionality of the legacy PortrAI photobooth setup application. This app provides a modern, cross-platform solution for managing photobooth themes and configurations.

## Features

### ✅ Implemented Features

1. **Authentication System**
   - Firebase Authentication integration
   - Email/password login
   - User session management
   - Secure user profile management

2. **Theme Management**
   - Create, edit, and delete photobooth themes
   - Upload theme thumbnails
   - Configure processing URLs
   - Collection-based organization

3. **User Interface**
   - Modern Material Design 3 interface
   - Dark/Light theme switching
   - Responsive layout matching legacy app
   - User profile widget with dropdown menu

4. **Data Management**
   - Firebase Firestore integration
   - Real-time data synchronization
   - Local caching for offline support
   - Secure data storage

5. **State Management**
   - Provider pattern for state management
   - Reactive UI updates
   - Centralized app state

### 🚧 Features to Implement

1. **Image Processing**
   - Batch image processing
   - Drag and drop file handling
   - Image upload to Firebase Storage
   - Processing status indicators

2. **Advanced UI Features**
   - Add/Edit preset dialogs
   - File picker integration
   - Progress indicators
   - Error handling and validation

## Project Structure

```
lib/
├── models/           # Data models
│   ├── preset.dart
│   ├── collection.dart
│   └── user.dart
├── services/         # Business logic
│   ├── auth_service.dart
│   └── firebase_config.dart
├── providers/        # State management
│   └── app_state.dart
├── screens/          # UI screens
│   ├── main_screen.dart
│   └── login_screen.dart
├── widgets/          # Reusable components
│   ├── theme_configuration_section.dart
│   ├── preset_card.dart
│   └── user_profile_widget.dart
├── theme/           # App theming
│   └── app_theme.dart
└── main.dart        # App entry point
```

## Dependencies

- **firebase_core**: Firebase initialization
- **firebase_auth**: User authentication
- **cloud_firestore**: Database operations
- **firebase_storage**: File storage
- **provider**: State management
- **http**: HTTP requests
- **file_picker**: File selection
- **image_picker**: Image handling
- **flutter_dropzone**: Drag and drop
- **shared_preferences**: Local storage
- **uuid**: ID generation

## Setup Instructions

### Prerequisites

1. **Flutter SDK** (3.24.5 or later)
2. **Firebase Project** with the following services enabled:
   - Authentication
   - Firestore Database
   - Storage

### Installation

1. **Clone the repository**
   ```bash
   git clone <repository-url>
   cd portrai_flutter_app
   ```

2. **Install dependencies**
   ```bash
   flutter pub get
   ```

3. **Configure Firebase**
   - Create a Firebase project
   - Enable Authentication, Firestore, and Storage
   - Update `lib/services/firebase_config.dart` with your Firebase configuration

4. **Run the app**
   ```bash
   # For development
   flutter run
   
   # For Windows build
   flutter build windows
   ```

## Windows Deployment

### Building for Windows

1. **Install Flutter on Windows**
   ```bash
   # Download Flutter SDK for Windows
   # Extract to C:\flutter
   # Add C:\flutter\bin to PATH
   ```

2. **Enable Windows desktop support**
   ```bash
   flutter config --enable-windows-desktop
   ```

3. **Build the app**
   ```bash
   flutter build windows --release
   ```

4. **Deploy**
   - The built app will be in `build/windows/runner/Release/`
   - Copy the entire `Release` folder to target Windows machines
   - Run `portrai_flutter_app.exe`

### Windows Requirements

- Windows 10 version 1903 or later
- Visual Studio 2019 or later (for building)
- Windows SDK 10.0.19041.0 or later

## Configuration

### Firebase Setup

1. **Create Firebase Project**
   - Go to [Firebase Console](https://console.firebase.google.com/)
   - Create a new project
   - Enable Authentication, Firestore, and Storage

2. **Configure Authentication**
   - Enable Email/Password authentication
   - Set up authorized domains

3. **Configure Firestore**
   - Create database in production mode
   - Set up security rules for user data

4. **Update Configuration**
   - Replace Firebase configuration in `lib/services/firebase_config.dart`
   - Update the Firebase options in `main.dart`

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

## Development

### Code Structure

- **Models**: Data classes with serialization
- **Services**: Business logic and API calls
- **Providers**: State management with Provider pattern
- **Screens**: Full-screen UI components
- **Widgets**: Reusable UI components
- **Theme**: App-wide styling and theming

### Adding New Features

1. **Create Models**: Define data structures in `lib/models/`
2. **Implement Services**: Add business logic in `lib/services/`
3. **Update State**: Modify `lib/providers/app_state.dart`
4. **Create UI**: Build screens and widgets
5. **Update Navigation**: Add routing logic

### Testing

```bash
# Run tests
flutter test

# Run integration tests
flutter test integration_test/

# Analyze code
flutter analyze
```

## Legacy App Compatibility

This Flutter app maintains full compatibility with the legacy Python application:

- **Same Firebase Configuration**: Uses identical Firebase project and settings
- **Data Structure**: Preserves all data models and relationships
- **User Experience**: Matches the original UI/UX design
- **Functionality**: Implements all core features from the legacy app

## Troubleshooting

### Common Issues

1. **Firebase Connection**
   - Verify Firebase configuration
   - Check network connectivity
   - Ensure Firebase services are enabled

2. **Build Issues**
   - Run `flutter clean`
   - Delete `pubspec.lock`
   - Run `flutter pub get`

3. **Windows Build**
   - Ensure Visual Studio is installed
   - Check Windows SDK version
   - Verify Flutter Windows desktop support

### Support

For issues and questions:
1. Check the troubleshooting section
2. Review Firebase documentation
3. Check Flutter Windows desktop documentation
4. Create an issue in the repository

## License

This project is proprietary software. All rights reserved.