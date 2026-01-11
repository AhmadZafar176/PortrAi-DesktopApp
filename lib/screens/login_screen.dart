import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:io';
import '../providers/app_state.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _escFocusNode = FocusNode();
  bool _isLoading = false;
  String? _errorMessage;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _escFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RawKeyboardListener(
      autofocus: true,
      focusNode: _escFocusNode,
      onKey: (event) async {
        if (event.isKeyPressed(LogicalKeyboardKey.escape)) {
          if (!_isLoading) {
            final shouldExit = await _confirmExitDialog();
            if (shouldExit) {
              if (Platform.isWindows) {
                await windowManager.close();
              } else {
                Navigator.of(context).maybePop();
              }
            }
          }
        }
      },
      child: Scaffold(
      backgroundColor: const Color(0xFF0B1120),
      body: Center(
        child: SingleChildScrollView(
          child: Container(
            width: 450,
            constraints: const BoxConstraints(
              minHeight: 600,
              maxHeight: 800,
            ),
            padding: const EdgeInsets.all(40),
            decoration: BoxDecoration(
              color: const Color(0xFF0B1120),
              border: Border.all(color: const Color(0xFF374151)),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [

                const Text(
                  'PortrAI',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFFCC66FF),
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 8),

                const Text(
                  'Welcome back! Please sign in to continue.',
                  style: TextStyle(
                    fontSize: 16,
                    color: Color(0xFF9CA3AF),
                    height: 1.4,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 40),

                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [

                    const Text(
                      'Email',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _emailController,
                      decoration: const InputDecoration(
                        hintText: 'Enter your email',
                        hintStyle: TextStyle(color: Color(0xFF6B7280)),
                        filled: true,
                        fillColor: Color(0xFF1F2937),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(8)),
                          borderSide: BorderSide(color: Color(0xFF374151)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(8)),
                          borderSide: BorderSide(color: Color(0xFF374151)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(8)),
                          borderSide: BorderSide(color: Color(0xFFCC66FF), width: 2),
                        ),
                        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      ),
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      keyboardType: TextInputType.emailAddress,
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Please enter your email';
                        }
                        if (!value.contains('@')) {
                          return 'Please enter a valid email';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),

                    const Text(
                      'Password',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _passwordController,
                      decoration: const InputDecoration(
                        hintText: 'Enter your password',
                        hintStyle: TextStyle(color: Color(0xFF6B7280)),
                        filled: true,
                        fillColor: Color(0xFF1F2937),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(8)),
                          borderSide: BorderSide(color: Color(0xFF374151)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(8)),
                          borderSide: BorderSide(color: Color(0xFF374151)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.all(Radius.circular(8)),
                          borderSide: BorderSide(color: Color(0xFFCC66FF), width: 2),
                        ),
                        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      ),
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                      obscureText: true,
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Please enter your password';
                        }
                        if (value.length < 6) {
                          return 'Password must be at least 6 characters';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 24),

                        if (_errorMessage != null)
                          Container(
                            padding: const EdgeInsets.all(12),
                            margin: const EdgeInsets.only(bottom: 16),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEF4444).withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: const Color(0xFFEF4444)),
                            ),
                            child: SingleChildScrollView(
                              child: Text(
                                _errorMessage!,
                                style: const TextStyle(
                                  color: Color(0xFFEF4444),
                                  fontSize: 12,
                                ),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),

                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _signIn,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFCC66FF),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          elevation: 0,
                        ),
                        child: _isLoading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text(
                                'Sign In',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
                
                const SizedBox(height: 24),

                Row(
                  children: [
                    Expanded(
                      child: Container(
                        height: 1,
                        color: const Color(0xFF374151),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        'or',
                        style: TextStyle(
                          color: Color(0xFF9CA3AF),
                          fontSize: 14,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Container(
                        height: 1,
                        color: const Color(0xFF374151),
                      ),
                    ),
                  ],
                ),
                
                const SizedBox(height: 24),

                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _signInWithGoogle,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: const Color(0xFF1F2937),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                        side: const BorderSide(color: Color(0xFFD1D5DB)),
                      ),
                      elevation: 0,
                    ),
                    child: const Text(
                      'Sign in with Google',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                ],
              ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<bool> _confirmExitDialog() async {
    return await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) {
            return AlertDialog(
              backgroundColor: const Color(0xFF1F2937),
              title: const Text('Exit App?', style: TextStyle(color: Colors.white)),
              content: const Text(
                'Are you sure you want to exit?',
                style: TextStyle(color: Color(0xFF9CA3AF)),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Cancel', style: TextStyle(color: Color(0xFF9CA3AF))),
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('Yes', style: TextStyle(color: Color(0xFFCC66FF))),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  Future<void> _signIn() async {
    final form = _formKey.currentState;
    if (form == null) return;
    if (!form.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final appState = Provider.of<AppState>(context, listen: false);
      await appState.signInWithEmailAndPassword(
        _emailController.text.trim(),
        _passwordController.text,
      );

      await _bringAppToForeground();

    } catch (e) {
      setState(() {
        String errorCode = '';
        String errorMessage = '';
        
        if (e is FirebaseAuthException) {
          errorCode = e.code.toLowerCase();
          errorMessage = e.message?.toLowerCase() ?? '';
        } else {
          final errorString = e.toString().toLowerCase();
          errorMessage = errorString;
          
          final regex = RegExp(r'\[firebase\s+auth/([^\]]+)\]');
          final match = regex.firstMatch(errorString);
          if (match != null) {
            errorCode = match.group(1)?.toLowerCase() ?? '';
          } else {
            if (errorString.contains('wrong-password')) {
              errorCode = 'wrong-password';
            } else if (errorString.contains('user-not-found')) {
              errorCode = 'user-not-found';
            } else if (errorString.contains('invalid-credential')) {
              errorCode = 'invalid-credential';
            } else if (errorString.contains('invalid-email')) {
              errorCode = 'invalid-email';
            } else if (errorString.contains('unknown-error') || errorString.contains('auth/unknown-error')) {
              errorCode = 'unknown-error';
            }
          }
        }
        
        if (errorCode == 'wrong-password' || 
            errorCode == 'user-not-found' || 
            errorCode == 'invalid-credential' ||
            errorCode == 'invalid-email' ||
            errorCode == 'unknown-error') {
          _errorMessage = 'Wrong email/password, please recheck your credentials.';
        } else {
          _errorMessage = e.toString().replaceFirst('Exception: ', '');
        }
      });
      
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_escFocusNode.hasFocus) {
          _escFocusNode.requestFocus();
        }
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
      
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_escFocusNode.hasFocus) {
          _escFocusNode.requestFocus();
        }
      });
    }
  }

  Future<void> _signInWithGoogle() async {
    print('ðŸ” Google Sign-In button clicked!');
    
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      print('ðŸ” Calling appState.signInWithGoogle()...');
      final appState = Provider.of<AppState>(context, listen: false);
      await appState.signInWithGoogle();
      print('ðŸ” Google Sign-In completed successfully!');

      await Future.delayed(const Duration(milliseconds: 600));
      
      if (mounted) {
        await _bringAppToForeground();
      }

    } catch (e) {
      print('ðŸ” Google Sign-In error: $e');
      setState(() {
        String errorMsg = e.toString().replaceFirst('Exception: ', '');
        if (errorMsg.contains('People API has not been used')) {
          _errorMessage = 'Google Sign-In requires People API to be enabled. Please enable it in Google Cloud Console and try again.';
        } else {
          _errorMessage = errorMsg;
        }
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _bringAppToForeground() async {
    if (!Platform.isWindows) return;
    
    bool alwaysOnTopSet = false;
    
    try {
      if (!mounted) return;
      
      print('ðŸ” Bringing app window to foreground...');
      
      await windowManager.setAlwaysOnTop(true);
      alwaysOnTopSet = true;
      
      await windowManager.restore();
      await windowManager.show();
      await Future.delayed(const Duration(milliseconds: 50));
      await windowManager.focus();
      await windowManager.setFullScreen(true);
      
      await Future.delayed(const Duration(milliseconds: 200));
      
      if (mounted) {
        await windowManager.setAlwaysOnTop(false);
        alwaysOnTopSet = false;
      }
      
      print('ðŸ” App window brought to foreground successfully');
    } catch (e) {
      print('ðŸ” Error bringing app to foreground: $e');
      if (alwaysOnTopSet && mounted) {
        try {
          await windowManager.setAlwaysOnTop(false);
        } catch (_) {
          print('ðŸ” Error resetting alwaysOnTop');
        }
      }
    }
  }
}
