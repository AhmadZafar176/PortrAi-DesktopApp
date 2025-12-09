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

  final GoogleSignIn _googleSignIn = GoogleSignIn(
    clientId: Platform.isWindows
        ? FirebaseConfig.googleOAuthDesktopClientId
        : "955675066153-qam0h7sitso8pt7ki7blqu4ucf0jr3ea.apps.googleusercontent.com",
    scopes: ['openid', 'email', 'profile'],
  );

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
      throw Exception('Failed to sign in: $e');
    }
  }

  Future<app_user.User?> signInWithGoogle() async {
    try {
      print('🔍 AuthService: Starting Google Sign-In...');

      GoogleSignInAccount? googleUser;
      
      try {

        print('🔍 AuthService: Trying silent sign-in...');
        googleUser = await _googleSignIn.signInSilently();
        print('🔍 AuthService: Silent sign-in result: ${googleUser?.email}');
        
        if (googleUser == null) {

          print('🔍 AuthService: Silent sign-in failed, using signIn...');
          googleUser = await _googleSignIn.signIn();
          print('🔍 AuthService: Sign-in result: ${googleUser?.email}');
        }
      } catch (e) {
        print('🔍 AuthService: Sign-in error: $e');

        googleUser = await _googleSignIn.signIn();
        print('🔍 AuthService: Fallback sign-in result: ${googleUser?.email}');
      }
      
      if (googleUser == null) {

        print('🔍 AuthService: User cancelled sign-in');
        return null;
      }

      final GoogleSignInAuthentication googleAuth = await googleUser.authentication;

      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      final UserCredential result = await _auth.signInWithCredential(credential);
      
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
      return null;
    } catch (e) {
      print('🔍 AuthService: Google Sign-In failed: $e');
      throw Exception('Failed to sign in with Google: $e');
    }
  }

  Future<void> signOut() async {
    try {
      await _auth.signOut();

      if (!Platform.isWindows) {
        await _googleSignIn.signOut();
      }
    } catch (e) {
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

  Future<void> saveCollection(Collection collection) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('collections')
          .doc(collection.name)
          .set(collection.toMap());
    } catch (e) {
      throw Exception('Failed to save collection: $e');
    }
  }

  Future<void> deleteCollection(String collectionName) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      await _firestore
          .collection('users')
          .doc(user.uid)
          .collection('collections')
          .doc(collectionName)
          .delete();
    } catch (e) {
      throw Exception('Failed to delete collection: $e');
    }
  }
}
