import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_web_plugins/url_strategy.dart'; 
import 'package:Boxi/screens/servicio_tema.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:Boxi/web_catalog.dart';
import 'package:Boxi/screens/pantalla_splash.dart';
import 'package:Boxi/screens/servicio_anuncios.dart';
import 'package:Boxi/database/db_helper.dart';
import 'package:Boxi/screens/servicio_notificaciones.dart';
import 'package:Boxi/screens/servicio_fcm.dart'; 
import 'api_keys.dart'; // 🔥 NUEVO: Importamos el archivo de llaves oculto

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  if (kIsWeb) {
    usePathUrlStrategy();
  }

  try {
    if (kIsWeb) {
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: ApiKeys.firebaseWebApiKey,
          appId: "1:727763492929:web:3951e905984e8874d1a6c0",
          messagingSenderId: "727763492929",
          projectId: "boxi-4a68c",
          authDomain: "boxi-4a68c.firebaseapp.com",
          storageBucket: "boxi-4a68c.firebasestorage.app",
        ),
      );
    } else {
      await Firebase.initializeApp();
    }
  } catch (e) {
    debugPrint("Error inicializando Firebase: $e");
  }
  
  try {
    if (kIsWeb) {
      await ServicioTema.cargar();
    } else {
      await Future.wait([
        DBHelper.instance.database,
        ServicioTema.cargar(),
      ]);
    }
  } catch(e) {
    debugPrint("Error al cargar dependencias: $e");
  }

  runApp(const BoxiApp());

  if (!kIsWeb) {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    ServicioNotificaciones.inicializar();
    ServicioAnuncios.iniciar().catchError((e) => debugPrint("Error Anuncios: $e"));
    ServicioFCM.inicializar().catchError((e) => debugPrint("Error FCM: $e"));
  }
}

class BoxiApp extends StatelessWidget {
  const BoxiApp({super.key});

  @override
  Widget build(BuildContext context) {
    String? adminId = Uri.base.queryParameters['id'];

    if (adminId == null) {
      String fullUrl = Uri.base.toString();
      if (fullUrl.contains("id=")) {
        adminId = fullUrl.split("id=").last.split("&").first;
      }
    }

    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ServicioTema.modoTema,
      builder: (context, modoActual, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Boxi',
          themeMode: modoActual, 

          theme: ThemeData(
            brightness: Brightness.light,
            primaryColor: const Color(0xFF0D47A1),
            colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0D47A1)),
            useMaterial3: true,
            appBarTheme: const AppBarTheme(
              backgroundColor: Color(0xFF0D47A1),
              foregroundColor: Colors.white,
            ),
          ),

          darkTheme: ThemeData(
            brightness: Brightness.dark,
            primaryColor: const Color(0xFF1565C0),
            scaffoldBackgroundColor: const Color.fromARGB(255, 30, 30, 31),
            cardColor: const Color.fromARGB(255, 39, 38, 58),
            appBarTheme: const AppBarTheme(
              backgroundColor: Color.fromARGB(255, 34, 42, 13),
              foregroundColor: Color.fromARGB(255, 255, 255, 255),
            ),
            useMaterial3: true,
          ),
          
          home: adminId != null 
              ? CatalogoWeb(adminId: adminId) 
              : const PantallaSplash(),

          onGenerateRoute: (settings) {
            return MaterialPageRoute(
              builder: (context) => adminId != null 
                  ? CatalogoWeb(adminId: adminId) 
                  : const PantallaSplash(),
            );
          },
        );
      }
    );
  }
}