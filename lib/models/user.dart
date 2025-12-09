class User {
  final String uid;
  final String email;
  final String? displayName;
  final String? photoURL;
  final bool emailVerified;
  final DateTime? lastSignInTime;
  final DateTime? creationTime;

  const User({
    required this.uid,
    required this.email,
    this.displayName,
    this.photoURL,
    this.emailVerified = false,
    this.lastSignInTime,
    this.creationTime,
  });

  factory User.fromMap(Map<String, dynamic> map) {
    return User(
      uid: map['uid'] ?? "",
      email: map['email'] ?? "",
      displayName: map['displayName'],
      photoURL: map['photoURL'],
      emailVerified: map['emailVerified'] ?? false,
      lastSignInTime: map['lastSignInTime'] != null 
          ? DateTime.fromMillisecondsSinceEpoch(map['lastSignInTime'])
          : null,
      creationTime: map['creationTime'] != null 
          ? DateTime.fromMillisecondsSinceEpoch(map['creationTime'])
          : null,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'uid': uid,
      'email': email,
      'displayName': displayName,
      'photoURL': photoURL,
      'emailVerified': emailVerified,
      'lastSignInTime': lastSignInTime?.millisecondsSinceEpoch,
      'creationTime': creationTime?.millisecondsSinceEpoch,
    };
  }

  User copyWith({
    String? uid,
    String? email,
    String? displayName,
    String? photoURL,
    bool? emailVerified,
    DateTime? lastSignInTime,
    DateTime? creationTime,
  }) {
    return User(
      uid: uid ?? this.uid,
      email: email ?? this.email,
      displayName: displayName ?? this.displayName,
      photoURL: photoURL ?? this.photoURL,
      emailVerified: emailVerified ?? this.emailVerified,
      lastSignInTime: lastSignInTime ?? this.lastSignInTime,
      creationTime: creationTime ?? this.creationTime,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is User &&
        other.uid == uid &&
        other.email == email &&
        other.displayName == displayName &&
        other.photoURL == photoURL &&
        other.emailVerified == emailVerified &&
        other.lastSignInTime == lastSignInTime &&
        other.creationTime == creationTime;
  }

  @override
  int get hashCode {
    return Object.hash(
      uid,
      email,
      displayName,
      photoURL,
      emailVerified,
      lastSignInTime,
      creationTime,
    );
  }

  @override
  String toString() {
    return 'User(uid: $uid, email: $email, displayName: $displayName, photoURL: $photoURL, emailVerified: $emailVerified, lastSignInTime: $lastSignInTime, creationTime: $creationTime)';
  }
}


