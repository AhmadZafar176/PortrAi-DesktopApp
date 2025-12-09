import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_state.dart';
import 'chevron_widget.dart';

class UserProfileWidget extends StatefulWidget {
  const UserProfileWidget({super.key});

  @override
  State<UserProfileWidget> createState() => _UserProfileWidgetState();
}

class _UserProfileWidgetState extends State<UserProfileWidget> {
  bool _isMenuOpen = false;

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, appState, child) {
        if (appState.currentUser == null) {
          return const SizedBox.shrink();
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [

            AnimatedSize(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              child: _isMenuOpen ? _buildSlideOutMenu(appState) : const SizedBox.shrink(),
            ),

            _buildEnhancedProfileButton(appState),
          ],
        );
      },
    );
  }

  Widget _buildSlideOutMenu(dynamic appState) {
    return TweenAnimationBuilder<double>(
      duration: const Duration(milliseconds: 300),
      tween: Tween(begin: 0.0, end: 1.0),
      curve: Curves.easeInOut,
      builder: (context, value, child) {
        return Transform.translate(
          offset: Offset(0, -20 * (1 - value)),
          child: Opacity(
            opacity: value,
            child: Container(
              width: 200,
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: const Color(0xFF0B1120).withOpacity(0.95),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: const Color(0xFF7C3AED).withOpacity(0.3),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF7C3AED).withOpacity(0.2),
                    blurRadius: 16,
                    offset: const Offset(0, -4),
                  ),
                  BoxShadow(
                    color: Colors.black.withOpacity(0.4),
                    blurRadius: 20,
                    offset: const Offset(0, -6),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [

                  _buildSignOutItem(appState),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildSignOutItem(dynamic appState) {
    return StatefulBuilder(
      builder: (context, setState) {
        bool isHovered = false;
        
        return MouseRegion(
          onEnter: (_) => setState(() => isHovered = true),
          onExit: (_) => setState(() => isHovered = false),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            margin: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: isHovered 
                  ? const Color(0xFFEF4444).withOpacity(0.1)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: ListTile(
              leading: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                child: Text(
                  '🚪',
                  style: TextStyle(
                    fontSize: 20,
                    color: isHovered 
                        ? const Color(0xFFEF4444)
                        : const Color(0xFFEF4444).withOpacity(0.8),
                  ),
                ),
              ),
              title: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 150),
                style: TextStyle(
                  color: isHovered 
                      ? const Color(0xFFEF4444)
                      : const Color(0xFFEF4444).withOpacity(0.9),
                  fontSize: 14,
                  fontWeight: isHovered ? FontWeight.w600 : FontWeight.w500,
                ),
                child: const Text('Sign Out'),
              ),
              onTap: () {
                appState.signOut();
                _toggleMenu();
              },
              dense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildEnhancedProfileButton(dynamic appState) {
    return StatefulBuilder(
      builder: (context, setState) {
        bool isHovered = false;
        bool isFocused = false;
        
        return MouseRegion(
          onEnter: (_) => setState(() => isHovered = true),
          onExit: (_) => setState(() => isHovered = false),
          child: Focus(
            onFocusChange: (hasFocus) => setState(() => isFocused = hasFocus),
            child: GestureDetector(
              onTap: _toggleMenu,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 200,
                height: 60,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: isFocused 
                      ? const Color(0xFF0B1120).withOpacity(0.95)
                      : isHovered 
                          ? const Color(0xFF0B1120).withOpacity(0.9)
                          : const Color(0xFF0B1120).withOpacity(0.8),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isFocused 
                        ? const Color(0xFF7C3AED)
                        : isHovered
                            ? const Color(0xFF7C3AED).withOpacity(0.5)
                            : Colors.transparent,
                    width: isFocused ? 2 : 1,
                  ),
                  boxShadow: isFocused ? [
                    BoxShadow(
                      color: const Color(0xFF7C3AED).withOpacity(0.3),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ] : isHovered ? [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.3),
                      blurRadius: 12,
                      offset: const Offset(0, 3),
                    ),
                  ] : [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.2),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  children: [

                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0xFF6B7280),
                          width: 1,
                        ),
                      ),
                      child: ClipOval(
                        child: appState.currentUser!.photoURL != null
                            ? Image.network(
                                _getWebCompatibleImageUrl(appState.currentUser!.photoURL!),
                                width: 40,
                                height: 40,
                                fit: BoxFit.cover,
                                headers: const {
                                  'Access-Control-Allow-Origin': '*',
                                },
                                errorBuilder: (context, error, stackTrace) {
                                  print('🖼️ Image loading error: $error');
                                  print('🖼️ Stack trace: $stackTrace');
                                  return _buildFallbackAvatar(appState.currentUser!);
                                },
                              )
                            : _buildFallbackAvatar(appState.currentUser!),
                      ),
                    ),
                    
                    const SizedBox(width: 12),

                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            appState.currentUser!.displayName ?? 
                            appState.currentUser!.email.split('@')[0],
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            appState.currentUser!.email,
                            style: const TextStyle(
                              color: Color(0xFF94A3B8),
                              fontSize: 12,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),

                    AnimatedRotation(
                      turns: _isMenuOpen ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: const ChevronWidget(
                        isUpward: false,
                        color: Color(0xFF7C3AED),
                        size: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildFallbackAvatar(dynamic user) {

    String initials = '';
    if (user.displayName != null && user.displayName!.isNotEmpty) {
      final names = user.displayName!.split(' ');
      if (names.length >= 2) {
        initials = '${names[0][0]}${names[1][0]}'.toUpperCase();
      } else {
        initials = user.displayName![0].toUpperCase();
      }
    } else {

      final emailParts = user.email.split('@');
      initials = emailParts[0].substring(0, 1).toUpperCase();
    }

    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            Color(0xFF7C3AED),
            Color(0xFF8B5CF6),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF7C3AED).withOpacity(0.3),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Center(
        child: Text(
          initials,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }

  void _toggleMenu() {
    setState(() {
      _isMenuOpen = !_isMenuOpen;
    });
  }

  String _getWebCompatibleImageUrl(String photoURL) {
    print('🖼️ Original photo URL: $photoURL');


    if (photoURL.contains('googleusercontent.com')) {

      if (!photoURL.contains('sz=')) {
        final separator = photoURL.contains('?') ? '&' : '?';
        photoURL = '$photoURL${separator}sz=40';
      }
    }
    
    print('🖼️ Web-compatible photo URL: $photoURL');
    return photoURL;
  }
}

