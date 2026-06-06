import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'screens/home_screen.dart';
import 'screens/find_location_screen.dart'; // To initialize cams list

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  cams = await availableCameras();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Indoor Navigation',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.blue,
      ),
      home: const HomeScreen(),
    );
  }
}
