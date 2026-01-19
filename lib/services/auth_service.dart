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

  GoogleSignIn _createGoogleSignIn() {
    return GoogleSignIn(
      clientId: Platform.isWindows
          ? FirebaseConfig.googleOAuthDesktopClientId
          : "955675066153-qam0h7sitso8pt7ki7blqu4ucf0jr3ea.apps.googleusercontent.com",
      scopes: ['openid', 'email', 'profile'],
    );
  }

  GoogleSignIn? _currentGoogleSignIn;

  Future<void> _resetOAuthState() async {
    print('ðŸ” AuthService: Resetting OAuth state...');
    
    if (_currentGoogleSignIn != null) {
      for (int i = 0; i < 2; i++) {
        try {
          print('ðŸ” AuthService: Clearing previous GoogleSignIn instance (attempt ${i + 1}/2)...');
          try {
            await _currentGoogleSignIn!.signOut();
            print('ðŸ” AuthService: Signed out from previous instance');
          } catch (e) {
            print('ðŸ” AuthService: Note - Sign out error: $e');
          }
          
          try {
            await _currentGoogleSignIn!.disconnect();
            print('ðŸ” AuthService: Disconnected from previous instance');
          } catch (e) {
            print('ðŸ” AuthService: Note - Disconnect error: $e');
          }
          
          if (i < 1) {
            await Future.delayed(const Duration(milliseconds: 500));
          }
        } catch (e) {
          print('ðŸ” AuthService: Note - Error clearing previous instance: $e');
        }
      }
      _currentGoogleSignIn = null;
    }
    
    print('ðŸ” AuthService: Waiting for system OAuth cache to clear (browser/credential manager)...');
    await Future.delayed(const Duration(milliseconds: 2000));
    
    print('ðŸ” AuthService: OAuth state reset complete');
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
      if (e is FirebaseAuthException) {
        rethrow;
      }
      throw Exception('Failed to sign in: $e');
    }
  }

  Future<app_user.User?> signInWithGoogle() async {
    try {
      print('ðŸ” AuthService: Starting Google Sign-In...');

      try {
        final currentFirebaseUser = _auth.currentUser;
        if (currentFirebaseUser != null) {
          print('ðŸ” AuthService: Current Firebase user found (${currentFirebaseUser.email}), signing out first');
          await _auth.signOut();
          print('ðŸ” AuthService: Signed out from Firebase Auth');
          await Future.delayed(const Duration(milliseconds: 200));
        }
      } catch (e) {
        print('ðŸ” AuthService: Note - Firebase sign-out: $e');
      }

      await _resetOAuthState();
      
      final googleSignIn = _createGoogleSignIn();
      _currentGoogleSignIn = googleSignIn;
      
      print('ðŸ” AuthService: Created fresh GoogleSignIn instance');

      GoogleSignInAccount? googleUser;
      
      GoogleSignIn currentGoogleSignIn = googleSignIn;
      int signInRetries = 0;
      const maxSignInRetries = 3;
      
      while (signInRetries < maxSignInRetries) {
        try {
          print('ðŸ” AuthService: Requesting Google Sign-In with account picker (attempt ${signInRetries + 1}/$maxSignInRetries)...');
          googleUser = await currentGoogleSignIn.signIn();
          if (googleUser != null) {
            print('ðŸ” AuthService: Sign-in result: ${googleUser.email}');
          } else {
            print('ðŸ” AuthService: User cancelled sign-in');
          }
          break;
        } catch (e) {
          final errorString = e.toString().toLowerCase();
          final isServerError = errorString.contains('500') || 
                               errorString.contains('internal server error') ||
                               errorString.contains('internal-error');
          
          print('ðŸ” AuthService: Sign-in error details: $e');
          print('ðŸ” AuthService: Error type - Server error: $isServerError');
          
          if (isServerError && signInRetries < maxSignInRetries - 1) {
            signInRetries++;
            final delaySeconds = signInRetries * 2;
            print('ðŸ” AuthService: Google server error (500), retrying in ${delaySeconds}s... (attempt $signInRetries/$maxSignInRetries)');
            await Future.delayed(Duration(seconds: delaySeconds));
            
            print('ðŸ” AuthService: Creating fresh GoogleSignIn instance for retry...');
            try {
              await currentGoogleSignIn.signOut();
              try {
                await currentGoogleSignIn.disconnect();
              } catch (_) {
              }
            } catch (_) {
            }
            final retryGoogleSignIn = _createGoogleSignIn();
            _currentGoogleSignIn = retryGoogleSignIn;
            currentGoogleSignIn = retryGoogleSignIn;
            await Future.delayed(const Duration(milliseconds: 500));
            continue;
          } else {
            print('ðŸ” AuthService: Sign-in error (not retrying): $e');
            rethrow;
          }
        }
      }
      
      if (googleUser == null) {
        print('ðŸ” AuthService: User cancelled sign-in');
        return null;
      }

      GoogleSignInAuthentication? googleAuth;
      int tokenRetries = 0;
      const maxTokenRetries = 3;
      
      while (tokenRetries < maxTokenRetries) {
        try {
          print('ðŸ” AuthService: Requesting authentication tokens for ${googleUser.email} (attempt ${tokenRetries + 1}/$maxTokenRetries)...');
          googleAuth = await googleUser.authentication;
          print('ðŸ” AuthService: Got authentication tokens (accessToken: ${googleAuth.accessToken != null ? "present" : "null"}, idToken: ${googleAuth.idToken != null ? "present" : "null"})');
          break;
        } catch (e) {
          final errorString = e.toString().toLowerCase();
          final isServerError = errorString.contains('500') || 
                               errorString.contains('internal server error') ||
                               errorString.contains('internal-error');
          
          if (isServerError && tokenRetries < maxTokenRetries - 1) {
            tokenRetries++;
            final delaySeconds = tokenRetries * 2;
            print('ðŸ” AuthService: Google server error (500) getting tokens, retrying in ${delaySeconds}s... (attempt $tokenRetries/$maxTokenRetries)');
            await Future.delayed(Duration(seconds: delaySeconds));
            
            try {
              await currentGoogleSignIn.disconnect();
              await Future.delayed(const Duration(milliseconds: 500));
            } catch (_) {
            }
            continue;
          } else {
            print('ðŸ” AuthService: Failed to get authentication tokens: $e');
            if (isServerError) {
              throw Exception('Google authentication server error (500). Please try again in a few moments.');
            } else {
              throw Exception('Failed to authenticate with Google: $e');
            }
          }
        }
      }
      
      if (googleAuth == null) {
        throw Exception('Failed to get authentication tokens from Google after $maxTokenRetries attempts.');
      }

      if (googleAuth.accessToken == null || googleAuth.idToken == null) {
        print('ðŸ” AuthService: Missing authentication tokens');
        throw Exception('Failed to get authentication tokens from Google. Please try signing in again.');
      }

      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      UserCredential? result;
      int firebaseRetries = 0;
      const maxFirebaseRetries = 2;
      
      while (firebaseRetries < maxFirebaseRetries) {
        try {
          print('ðŸ” AuthService: Signing in to Firebase with Google credential (attempt ${firebaseRetries + 1}/$maxFirebaseRetries)...');
          result = await _auth.signInWithCredential(credential);
          break;
        } catch (e) {
          final errorString = e.toString().toLowerCase();
          final isServerError = errorString.contains('500') || 
                               errorString.contains('internal server error') ||
                               errorString.contains('internal-error');
          
          if (errorString.contains('user-not-found')) {
            throw Exception('Account not found. Please ensure you are using the correct Google account.');
          } else if (errorString.contains('account-exists-with-different-credential')) {
            throw Exception('An account already exists with a different sign-in method. Please use the original sign-in method.');
          } else if (errorString.contains('invalid-credential') || errorString.contains('invalid-id-token')) {
            throw Exception('Invalid credentials. Please try signing in again.');
          } else if (isServerError && firebaseRetries < maxFirebaseRetries - 1) {
            firebaseRetries++;
            final delaySeconds = firebaseRetries * 2;
            print('ðŸ” AuthService: Firebase server error (500), retrying in ${delaySeconds}s... (attempt $firebaseRetries/$maxFirebaseRetries)');
            await Future.delayed(Duration(seconds: delaySeconds));
            continue;
          } else if (errorString.contains('network') || errorString.contains('timeout')) {
            throw Exception('Network error. Please check your internet connection and try again.');
          } else if (errorString.contains('too-many-requests')) {
            throw Exception('Too many sign-in attempts. Please wait a moment and try again.');
          } else if (isServerError) {
            print('ðŸ” AuthService: Firebase server error (500) after retries');
            throw Exception('Firebase authentication server error (500). Please try again in a few moments.');
          }
          rethrow;
        }
      }
      
      if (result == null) {
        throw Exception('Failed to sign in to Firebase after $maxFirebaseRetries attempts.');
      }
      
      if (result.user != null) {
        print('ðŸ” AuthService: Firebase sign-in successful for ${result.user!.email}');
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
      
      print('ðŸ” AuthService: Firebase sign-in returned null user');
      return null;
    } catch (e) {
      print('ðŸ” AuthService: Google Sign-In failed: $e');
      final errorString = e.toString().toLowerCase();
      
      if (errorString.contains('sign_in_canceled') || 
          errorString.contains('cancelled') ||
          errorString.contains('user_cancelled')) {
        print('ðŸ” AuthService: User cancelled sign-in');
        return null;
      }
      
      String errorMessage = 'Failed to sign in with Google';
      final isServerError = errorString.contains('500') || 
                           errorString.contains('internal server error') ||
                           errorString.contains('internal-error');
      
      if (errorString.contains('network_error') || errorString.contains('network')) {
        errorMessage = 'Network error. Please check your internet connection and try again.';
      } else if (isServerError) {
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
      
      print('ðŸ” AuthService: Final error message: $errorMessage');
      print('ðŸ” AuthService: Full error details: $e');
      
      throw Exception('$errorMessage');
    }
  }

  Future<void> signOut() async {
    try {
      print('ðŸ” AuthService: Starting sign out...');
      
      await _auth.signOut();
      print('ðŸ” AuthService: Signed out from Firebase');

      if (_currentGoogleSignIn != null) {
        for (int i = 0; i < 2; i++) {
          try {
            print('ðŸ” AuthService: Clearing Google Sign-In state (attempt ${i + 1}/2)...');
            
            try {
              await _currentGoogleSignIn!.signOut();
              print('ðŸ” AuthService: Signed out from Google Sign-In (local state cleared)');
            } catch (e) {
              print('ðŸ” AuthService: Note - Sign out: $e');
            }
            
            try {
              await _currentGoogleSignIn!.disconnect();
              print('ðŸ” AuthService: Disconnected from Google Sign-In (OAuth tokens revoked)');
            } catch (e) {
              print('ðŸ” AuthService: Note - Disconnect not needed or failed: $e');
            }
            
            if (i < 1) {
              await Future.delayed(const Duration(milliseconds: 500));
            }
          } catch (e) {
            print('ðŸ” AuthService: Note - Google Sign-In sign-out: $e');
          }
        }
        
        _currentGoogleSignIn = null;
        print('ðŸ” AuthService: Cleared GoogleSignIn instance reference');
        
        await Future.delayed(const Duration(milliseconds: 1000));
      }
      
      print('ðŸ” AuthService: Sign out completed successfully');
    } catch (e) {
      print('ðŸ” AuthService: Sign out error: $e');
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
        final raw = doc.data();
        if (raw is Map<String, dynamic>) {
          return Preset.fromMap(raw);
        }
        if (raw is Map) {
          return Preset.fromMap(raw.cast<String, dynamic>());
        }
        return const Preset();
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
        final raw = doc.data();
        if (raw is Map<String, dynamic>) {
          return Collection.fromMap(raw);
        }
        if (raw is Map) {
          return Collection.fromMap(raw.cast<String, dynamic>());
        }
        return const Collection(id: '', name: '');
      }).toList();
    } catch (e) {
      throw Exception('Failed to fetch collections: $e');
    }
  }

}
