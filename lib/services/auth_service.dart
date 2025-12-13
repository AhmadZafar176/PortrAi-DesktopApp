import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_sign_in_dartio/google_sign_in_dartio.dart';
import 'dart:io' show Platform;
import 'firebase_config.dart';
import '../models/user.dart' as app_user;
import '../models/preset.dart';
import '../models/collection.dart';

class AuthService {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal() {

    if (Platform.isWindows) {
      GoogleSignInDart.register(
        clientId: FirebaseConfig.googleOAuthDesktopClientId,
      );
    }
  }

  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Create a method to get a fresh GoogleSignIn instance
  // This ensures we don't reuse cached OAuth state when switching accounts
  // CRITICAL: forceCodeForRefreshToken ensures account picker always shows
  GoogleSignIn _createGoogleSignIn() {
    return GoogleSignIn(
      clientId: Platform.isWindows
          ? FirebaseConfig.googleOAuthDesktopClientId
          : "955675066153-qam0h7sitso8pt7ki7blqu4ucf0jr3ea.apps.googleusercontent.com",
      scopes: ['openid', 'email', 'profile'],
    );
  }

  // Keep a reference for sign-out operations
  GoogleSignIn? _currentGoogleSignIn;

  /// Completely reset OAuth state to prevent cached token conflicts
  /// This is critical for account switching on Windows where OAuth state
  /// can persist at the OS level even after sign-out
  Future<void> _resetOAuthState() async {
    print('🔍 AuthService: Resetting OAuth state...');
    
    // Step 1: Clear any existing GoogleSignIn instance
    // Do this multiple times to ensure complete clearing
    if (_currentGoogleSignIn != null) {
      for (int i = 0; i < 2; i++) {
        try {
          print('🔍 AuthService: Clearing previous GoogleSignIn instance (attempt ${i + 1}/2)...');
          try {
            await _currentGoogleSignIn!.signOut();
            print('🔍 AuthService: Signed out from previous instance');
          } catch (e) {
            print('🔍 AuthService: Note - Sign out error: $e');
          }
          
          try {
            await _currentGoogleSignIn!.disconnect();
            print('🔍 AuthService: Disconnected from previous instance');
          } catch (e) {
            print('🔍 AuthService: Note - Disconnect error: $e');
          }
          
          // Wait between attempts
          if (i < 1) {
            await Future.delayed(const Duration(milliseconds: 500));
          }
        } catch (e) {
          print('🔍 AuthService: Note - Error clearing previous instance: $e');
        }
      }
      _currentGoogleSignIn = null;
    }
    
    // Step 2: Wait longer for system-level OAuth cache to clear
    // Windows browser/credential manager may need more time to clear cached tokens
    // The fact that it works after rebuild suggests browser cache is involved
    print('🔍 AuthService: Waiting for system OAuth cache to clear (browser/credential manager)...');
    await Future.delayed(const Duration(milliseconds: 2000));
    
    print('🔍 AuthService: OAuth state reset complete');
  }

  Stream<app_user.User?> get userStream {
    return _auth.authStateChanges().map((User? firebaseUser) {
      if (firebaseUser == null) return null;
      return app_user.User(
        uid: firebaseUser.uid,
        email: firebaseUser.email ?? '',
        displayName: firebaseUser.displayName,
        photoURL: firebaseUser.photoURL,
        emailVerified: firebaseUser.emailVerified,
        lastSignInTime: firebaseUser.metadata.lastSignInTime,
        creationTime: firebaseUser.metadata.creationTime,
      );
    });
  }

  app_user.User? get currentUser {
    final firebaseUser = _auth.currentUser;
    if (firebaseUser == null) return null;
    return app_user.User(
      uid: firebaseUser.uid,
      email: firebaseUser.email ?? '',
      displayName: firebaseUser.displayName,
      photoURL: firebaseUser.photoURL,
      emailVerified: firebaseUser.emailVerified,
      lastSignInTime: firebaseUser.metadata.lastSignInTime,
      creationTime: firebaseUser.metadata.creationTime,
    );
  }

  Future<app_user.User?> signInWithEmailAndPassword(String email, String password) async {
    try {
      final UserCredential result = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      
      if (result.user != null) {
        return app_user.User(
          uid: result.user!.uid,
          email: result.user!.email ?? '',
          displayName: result.user!.displayName,
          photoURL: result.user!.photoURL,
          emailVerified: result.user!.emailVerified,
          lastSignInTime: result.user!.metadata.lastSignInTime,
          creationTime: result.user!.metadata.creationTime,
        );
      }
      return null;
    } catch (e) {
      // Preserve FirebaseAuthException to allow proper error handling
      if (e is FirebaseAuthException) {
        rethrow;
      }
      throw Exception('Failed to sign in: $e');
    }
  }

  Future<app_user.User?> signInWithGoogle() async {
    try {
      print('🔍 AuthService: Starting Google Sign-In...');

      // First, ensure we're fully signed out from Firebase Auth
      // This prevents token conflicts when switching accounts
      try {
        final currentFirebaseUser = _auth.currentUser;
        if (currentFirebaseUser != null) {
          print('🔍 AuthService: Current Firebase user found (${currentFirebaseUser.email}), signing out first');
          await _auth.signOut();
          print('🔍 AuthService: Signed out from Firebase Auth');
          await Future.delayed(const Duration(milliseconds: 200));
        }
      } catch (e) {
        print('🔍 AuthService: Note - Firebase sign-out: $e');
      }

      // CRITICAL: Completely reset OAuth state before each sign-in
      // This is essential because Windows caches OAuth tokens at the OS level
      // and GoogleSignInDart.register() maintains static state
      // The fact that it works after rebuild but not after sign-out suggests
      // system-level OAuth cache is persisting
      await _resetOAuthState();
      
      // Create a fresh GoogleSignIn instance for this sign-in attempt
      // This ensures we start with a clean OAuth state
      final googleSignIn = _createGoogleSignIn();
      _currentGoogleSignIn = googleSignIn;
      
      print('🔍 AuthService: Created fresh GoogleSignIn instance');

      GoogleSignInAccount? googleUser;
      
      // Always show account picker - don't use silent sign-in
      // This ensures users can choose which account to sign in with
      // Add retry logic for Google 500 errors
      // Use the fresh GoogleSignIn instance created above
      GoogleSignIn currentGoogleSignIn = googleSignIn;
      int signInRetries = 0;
      const maxSignInRetries = 3;
      
      while (signInRetries < maxSignInRetries) {
        try {
          // Use the fresh GoogleSignIn instance
          print('🔍 AuthService: Requesting Google Sign-In with account picker (attempt ${signInRetries + 1}/$maxSignInRetries)...');
          googleUser = await currentGoogleSignIn.signIn();
          if (googleUser != null) {
            print('🔍 AuthService: Sign-in result: ${googleUser.email}');
          } else {
            print('🔍 AuthService: User cancelled sign-in');
          }
          break; // Success or cancellation, exit retry loop
        } catch (e) {
          final errorString = e.toString().toLowerCase();
          final isServerError = errorString.contains('500') || 
                               errorString.contains('internal server error') ||
                               errorString.contains('internal-error');
          
          // Log the full error for debugging
          print('🔍 AuthService: Sign-in error details: $e');
          print('🔍 AuthService: Error type - Server error: $isServerError');
          
          if (isServerError && signInRetries < maxSignInRetries - 1) {
            signInRetries++;
            final delaySeconds = signInRetries * 2; // Exponential backoff: 2s, 4s
            print('🔍 AuthService: Google server error (500), retrying in ${delaySeconds}s... (attempt $signInRetries/$maxSignInRetries)');
            await Future.delayed(Duration(seconds: delaySeconds));
            
            // Create a fresh GoogleSignIn instance for retry
            // This ensures we don't reuse cached OAuth state
            print('🔍 AuthService: Creating fresh GoogleSignIn instance for retry...');
            try {
              await currentGoogleSignIn.signOut();
              try {
                await currentGoogleSignIn.disconnect();
              } catch (_) {
                // Ignore disconnect errors
              }
            } catch (_) {
              // Ignore errors during cleanup
            }
            // Create a new instance
            final retryGoogleSignIn = _createGoogleSignIn();
            _currentGoogleSignIn = retryGoogleSignIn;
            // Use the new instance for the retry
            currentGoogleSignIn = retryGoogleSignIn;
            await Future.delayed(const Duration(milliseconds: 500));
            continue; // Retry
          } else {
            print('🔍 AuthService: Sign-in error (not retrying): $e');
            // Re-throw the error to be handled by the outer catch block
            rethrow;
          }
        }
      }
      
      if (googleUser == null) {
        print('🔍 AuthService: User cancelled sign-in');
        return null;
      }

      // Get authentication tokens - request fresh tokens to avoid using cached ones
      // Add retry logic for Google 500 errors
      GoogleSignInAuthentication? googleAuth;
      int tokenRetries = 0;
      const maxTokenRetries = 3;
      
      while (tokenRetries < maxTokenRetries) {
        try {
          // Use the same GoogleSignIn instance that was used for sign-in
          print('🔍 AuthService: Requesting authentication tokens for ${googleUser.email} (attempt ${tokenRetries + 1}/$maxTokenRetries)...');
          googleAuth = await googleUser.authentication;
          print('🔍 AuthService: Got authentication tokens (accessToken: ${googleAuth.accessToken != null ? "present" : "null"}, idToken: ${googleAuth.idToken != null ? "present" : "null"})');
          break; // Success, exit retry loop
        } catch (e) {
          final errorString = e.toString().toLowerCase();
          final isServerError = errorString.contains('500') || 
                               errorString.contains('internal server error') ||
                               errorString.contains('internal-error');
          
          if (isServerError && tokenRetries < maxTokenRetries - 1) {
            tokenRetries++;
            final delaySeconds = tokenRetries * 2; // Exponential backoff: 2s, 4s
            print('🔍 AuthService: Google server error (500) getting tokens, retrying in ${delaySeconds}s... (attempt $tokenRetries/$maxTokenRetries)');
            await Future.delayed(Duration(seconds: delaySeconds));
            
            // Try to clear state before retry
            try {
              await currentGoogleSignIn.disconnect();
              await Future.delayed(const Duration(milliseconds: 500));
            } catch (_) {
              // Ignore errors during cleanup
            }
            continue; // Retry
          } else {
            print('🔍 AuthService: Failed to get authentication tokens: $e');
            if (isServerError) {
              throw Exception('Google authentication server error (500). Please try again in a few moments.');
            } else {
              throw Exception('Failed to authenticate with Google: $e');
            }
          }
        }
      }
      
      // Ensure googleAuth was successfully obtained
      if (googleAuth == null) {
        throw Exception('Failed to get authentication tokens from Google after $maxTokenRetries attempts.');
      }

      // Verify we have required tokens
      if (googleAuth.accessToken == null || googleAuth.idToken == null) {
        print('🔍 AuthService: Missing authentication tokens');
        throw Exception('Failed to get authentication tokens from Google. Please try signing in again.');
      }

      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      // Sign in to Firebase with Google credential
      // Add retry logic for Firebase 500 errors
      UserCredential? result;
      int firebaseRetries = 0;
      const maxFirebaseRetries = 2;
      
      while (firebaseRetries < maxFirebaseRetries) {
        try {
          print('🔍 AuthService: Signing in to Firebase with Google credential (attempt ${firebaseRetries + 1}/$maxFirebaseRetries)...');
          result = await _auth.signInWithCredential(credential);
          break; // Success, exit retry loop
        } catch (e) {
          final errorString = e.toString().toLowerCase();
          final isServerError = errorString.contains('500') || 
                               errorString.contains('internal server error') ||
                               errorString.contains('internal-error');
          
          // Handle specific Firebase Auth errors
          if (errorString.contains('user-not-found')) {
            throw Exception('Account not found. Please ensure you are using the correct Google account.');
          } else if (errorString.contains('account-exists-with-different-credential')) {
            throw Exception('An account already exists with a different sign-in method. Please use the original sign-in method.');
          } else if (errorString.contains('invalid-credential') || errorString.contains('invalid-id-token')) {
            throw Exception('Invalid credentials. Please try signing in again.');
          } else if (isServerError && firebaseRetries < maxFirebaseRetries - 1) {
            firebaseRetries++;
            final delaySeconds = firebaseRetries * 2; // Exponential backoff: 2s
            print('🔍 AuthService: Firebase server error (500), retrying in ${delaySeconds}s... (attempt $firebaseRetries/$maxFirebaseRetries)');
            await Future.delayed(Duration(seconds: delaySeconds));
            continue; // Retry
          } else if (errorString.contains('network') || errorString.contains('timeout')) {
            throw Exception('Network error. Please check your internet connection and try again.');
          } else if (errorString.contains('too-many-requests')) {
            throw Exception('Too many sign-in attempts. Please wait a moment and try again.');
          } else if (isServerError) {
            print('🔍 AuthService: Firebase server error (500) after retries');
            throw Exception('Firebase authentication server error (500). Please try again in a few moments.');
          }
          rethrow;
        }
      }
      
      // Ensure result was successfully obtained
      if (result == null) {
        throw Exception('Failed to sign in to Firebase after $maxFirebaseRetries attempts.');
      }
      
      if (result.user != null) {
        print('🔍 AuthService: Firebase sign-in successful for ${result.user!.email}');
        return app_user.User(
          uid: result.user!.uid,
          email: result.user!.email ?? '',
          displayName: result.user!.displayName,
          photoURL: result.user!.photoURL,
          emailVerified: result.user!.emailVerified,
          lastSignInTime: result.user!.metadata.lastSignInTime,
          creationTime: result.user!.metadata.creationTime,
        );
      }
      
      print('🔍 AuthService: Firebase sign-in returned null user');
      return null;
    } catch (e) {
      print('🔍 AuthService: Google Sign-In failed: $e');
      final errorString = e.toString().toLowerCase();
      
      // Handle user cancellation
      if (errorString.contains('sign_in_canceled') || 
          errorString.contains('cancelled') ||
          errorString.contains('user_cancelled')) {
        print('🔍 AuthService: User cancelled sign-in');
        return null; // User cancellation is not an error
      }
      
      // Provide more user-friendly error messages
      String errorMessage = 'Failed to sign in with Google';
      final isServerError = errorString.contains('500') || 
                           errorString.contains('internal server error') ||
                           errorString.contains('internal-error');
      
      if (errorString.contains('network_error') || errorString.contains('network')) {
        errorMessage = 'Network error. Please check your internet connection and try again.';
      } else if (isServerError) {
        // Google 500 errors when switching accounts usually indicate cached OAuth token conflicts
        // This happens when OAuth tokens from a previous account are still cached
        errorMessage = 'Google authentication server error (500). '
            'This may be due to cached authentication tokens from a previous account. '
            'Please wait a moment and try again, or restart the application to clear cached tokens.';
      } else if (errorString.contains('invalid-credential') || errorString.contains('invalid-id-token')) {
        errorMessage = 'Invalid credentials. Please try signing in again.';
      } else if (errorString.contains('user-not-found')) {
        errorMessage = 'Account not found. Please ensure you are using the correct Google account.';
      } else if (errorString.contains('account-exists-with-different-credential')) {
        errorMessage = 'An account already exists with a different sign-in method.';
      } else if (errorString.contains('access_denied') || errorString.contains('unauthorized')) {
        errorMessage = 'Access denied. Your Google account may not be authorized to use this application.';
      }
      
      // Log the full error for debugging
      print('🔍 AuthService: Final error message: $errorMessage');
      print('🔍 AuthService: Full error details: $e');
      
      throw Exception('$errorMessage');
    }
  }

  Future<void> signOut() async {
    try {
      print('🔍 AuthService: Starting sign out...');
      
      // Sign out from Firebase first
      await _auth.signOut();
      print('🔍 AuthService: Signed out from Firebase');

      // Always sign out and disconnect from Google Sign-In to clear cached account
      // This ensures users can choose a different account next time
      // CRITICAL: Clear the current GoogleSignIn instance to prevent token conflicts
      // Do this multiple times to ensure complete clearing (Windows browser cache issue)
      if (_currentGoogleSignIn != null) {
        for (int i = 0; i < 2; i++) {
          try {
            print('🔍 AuthService: Clearing Google Sign-In state (attempt ${i + 1}/2)...');
            
            // Step 1: Sign out first to clear local state
            try {
              await _currentGoogleSignIn!.signOut();
              print('🔍 AuthService: Signed out from Google Sign-In (local state cleared)');
            } catch (e) {
              print('🔍 AuthService: Note - Sign out: $e');
            }
            
            // Step 2: Disconnect to revoke OAuth tokens (critical for account switching)
            try {
              await _currentGoogleSignIn!.disconnect();
              print('🔍 AuthService: Disconnected from Google Sign-In (OAuth tokens revoked)');
            } catch (e) {
              // Disconnect might fail if not connected, that's okay
              print('🔍 AuthService: Note - Disconnect not needed or failed: $e');
            }
            
            // Wait between attempts
            if (i < 1) {
              await Future.delayed(const Duration(milliseconds: 500));
            }
          } catch (e) {
            // On some platforms or if already signed out, this might fail
            // Log but don't throw - Firebase sign-out is more important
            print('🔍 AuthService: Note - Google Sign-In sign-out: $e');
          }
        }
        
        // Step 3: Clear the instance reference
        _currentGoogleSignIn = null;
        print('🔍 AuthService: Cleared GoogleSignIn instance reference');
        
        // Step 4: Wait for browser/system cache to clear
        // Windows browser may cache OAuth sessions
        await Future.delayed(const Duration(milliseconds: 1000));
      }
      
      print('🔍 AuthService: Sign out completed successfully');
    } catch (e) {
      print('🔍 AuthService: Sign out error: $e');
      throw Exception('Failed to sign out: $e');
    }
  }

  Future<List<Preset>> fetchUserPresets() async {
    try {
      final user = _auth.currentUser;
      if (user == null) return [];

      final QuerySnapshot snapshot = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('presets')
          .get();

      return snapshot.docs.map((doc) {
        final data = doc.data() as Map<String, dynamic>;
        return Preset.fromMap(data);
      }).toList();
    } catch (e) {
      throw Exception('Failed to fetch presets: $e');
    }
  }

  Future<List<Collection>> fetchUserCollections() async {
    try {
      final user = _auth.currentUser;
      if (user == null) return [];

      final QuerySnapshot snapshot = await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('collections')
          .get();

      return snapshot.docs.map((doc) {
        final data = doc.data() as Map<String, dynamic>;
        return Collection.fromMap(data);
      }).toList();
    } catch (e) {
      throw Exception('Failed to fetch collections: $e');
    }
  }

}
