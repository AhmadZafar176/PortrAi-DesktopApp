class FirebaseConfig {
  // Firebase configuration matching the legacy app
  static const String apiKey = "***REMOVED***";
  static const String authDomain = "ai-booth-edda3.firebaseapp.com";
  static const String projectId = "ai-booth-edda3";
  static const String storageBucket = "ai-booth-edda3.firebasestorage.app";
  static const String messagingSenderId = "955675066153";
  static const String appId = "1:955675066153:web:04fa7741f68d8ee13dc138";
  static const String measurementId = "G-99XMEBVT7W";

  // Google OAuth configuration
  // Desktop client ID (for legacy app)
  static const String googleOAuthDesktopClientId = "955675066153-6prtbeehf3dmqn47ap8ehjv36cbto62v.apps.googleusercontent.com";
  static const String googleOAuthDesktopClientSecret = "***REMOVED***";
  
  // Web client ID (for Flutter web app)
  static const String googleOAuthWebClientId = "955675066153-qam0h7sitso8pt7ki7blqu4ucf0jr3ea.apps.googleusercontent.com";
  static const String googleOAuthWebClientSecret = "***REMOVED***";

  static Map<String, String> get firebaseOptions => {
    'apiKey': apiKey,
    'authDomain': authDomain,
    'projectId': projectId,
    'storageBucket': storageBucket,
    'messagingSenderId': messagingSenderId,
    'appId': appId,
    'measurementId': measurementId,
  };
}
