import 'package:flutter/material.dart';

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white, // or your theme color
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Optional: Add a logo or app name
            Icon(Icons.chat_bubble_outline, size: 80, color: const Color.fromARGB(255, 58, 183, 64)),
            const SizedBox(height: 20),
            const Text(
              'SLT Chat',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: Color.fromARGB(255, 58, 183, 127),
              ),
            ),
            const SizedBox(height: 40),
            const CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation<Color>(Color.fromARGB(255, 58, 183, 62)),
            ),
          ],
        ),
      ),
    );
  }
}
