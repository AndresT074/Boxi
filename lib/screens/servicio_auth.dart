import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../database/db_helper.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:google_sign_in/google_sign_in.dart';

class ServicioAuth {
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final FirebaseFirestore _db = FirebaseFirestore.instance;

  static Future<User?> registrarUsuario(String email, String password) async {
    try {
      _auth.setLanguageCode('es');
      
      UserCredential userCredential = await _auth.createUserWithEmailAndPassword(email: email, password: password);
      await userCredential.user!.sendEmailVerification();
      
      final prefs = await SharedPreferences.getInstance();
      String nombreActual = prefs.getString('nombre_negocio') ?? 'nombredenegocioaqui';

      await _db.collection('usuarios').doc(userCredential.user!.uid).set({
        'email': email,
        'es_premium': false,
        'nombre_negocio': nombreActual, 
        'fecha_registro': DateTime.now().toIso8601String(),
        'plan': 'Gratis'
      });
      
      return userCredential.user;
    } catch (e) { 
      return null; 
    }
  }

  static Future<User?> loginUsuario(String email, String password) async {
    try {
      UserCredential userCredential = await _auth.signInWithEmailAndPassword(email: email, password: password);
      if (!userCredential.user!.emailVerified) {
        await _auth.signOut();
        throw "EMAIL_NOT_VERIFIED";
      }
      final String uid = userCredential.user!.uid;
      try {
        PackageInfo packageInfo = await PackageInfo.fromPlatform();
        String versionActual = '${packageInfo.version}+${packageInfo.buildNumber}';
        await _db.collection('usuarios').doc(uid).set({
          'fecha_ultimo_ingreso': DateTime.now().toIso8601String(),
          'version_app': versionActual,
        }, SetOptions(merge: true));
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('ultimo_registro_firestore', DateTime.now().toIso8601String().substring(0, 10));
        await prefs.setString('version_app_registrada', versionActual);
      } catch (e) {
        print("Error registrando versión en login: $e");
      }
      await actualizarEstadoPremiumNube(uid);
      return userCredential.user;
    } catch (e) { 
      rethrow; 
    }
  }

  static Future<User?> loginConGoogle() async {
    try {
      final GoogleSignInAccount? googleUser = await GoogleSignIn().signIn();
      if (googleUser == null) return null; // El usuario canceló el inicio

      final GoogleSignInAuthentication googleAuth = await googleUser.authentication;
      final AuthCredential credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      UserCredential userCredential = await _auth.signInWithCredential(credential);
      User? user = userCredential.user;

      if (user != null) {
        final prefs = await SharedPreferences.getInstance();
        final docRef = _db.collection('usuarios').doc(user.uid);
        final docSnap = await docRef.get();

        PackageInfo packageInfo = await PackageInfo.fromPlatform();
        String versionActual = '${packageInfo.version}+${packageInfo.buildNumber}';

        if (!docSnap.exists) {
          // ES REGISTRO NUEVO
          String nombreActual = prefs.getString('nombre_negocio') ?? 'nombredenegocioaqui';
          await docRef.set({
            'email': user.email,
            'es_premium': false,
            'nombre_negocio': nombreActual,
            'fecha_registro': DateTime.now().toIso8601String(),
            'fecha_ultimo_ingreso': DateTime.now().toIso8601String(),
            'version_app': versionActual,
            'plan': 'Gratis'
          });
        } else {
          // ES LOGIN (YA EXISTÍA)
          await docRef.update({
            'fecha_ultimo_ingreso': DateTime.now().toIso8601String(),
            'version_app': versionActual,
          });
        }

        await prefs.setString('ultimo_registro_firestore', DateTime.now().toIso8601String().substring(0, 10));
        await prefs.setString('version_app_registrada', versionActual);
        await actualizarEstadoPremiumNube(user.uid);
      } 

      return user;
    } catch (e) {
      print("Error en Google Sign-In: $e");
      return null;
    }
  }

  static Future<bool> enviarRecuperacionPassword(String email) async {
    try {
      _auth.setLanguageCode('es'); 
      await _auth.sendPasswordResetEmail(email: email);
      return true;
    } catch (e) {
      return false;
    }
  }

  static Future<void> actualizarEstadoPremiumNube(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    try {
      DocumentSnapshot doc = await _db.collection('usuarios').doc(uid).get();
      if (doc.exists) {
        Map<String, dynamic> data = doc.data() as Map<String, dynamic>;
        bool esPremiumNube = data['es_premium'] ?? false;
        await prefs.setBool('es_premium', esPremiumNube);
      }
    } catch (e) { print(e); }
  }

  // Busca el método cerrarSesion en servicio_auth.dart:

  static Future<void> cerrarSesion() async {
    final user = _auth.currentUser;
    final prefs = await SharedPreferences.getInstance();

    // 🔥 Verificar en nube antes de decidir si limpiar datos
    bool esPremiumFinal = false;
    if (user != null) {
      try {
        final doc = await _db.collection('usuarios').doc(user.uid).get()
            .timeout(const Duration(seconds: 5));
        esPremiumFinal = doc.data()?['es_premium'] ?? false;
        if (esPremiumFinal) await prefs.setBool('es_premium', true);
      } catch (e) {
        // Sin internet: usamos lo que hay localmente
        esPremiumFinal = prefs.getBool('es_premium') ?? false;
      }
    }

    // Solo limpiar datos si NO es premium
    if (!esPremiumFinal) {
      await DBHelper.instance.limpiarTablas();
    }

    await prefs.setBool('es_premium', false);
    await prefs.setString('nombre_negocio', 'nombredenegocioaqui');
    await prefs.setString('logo_path', '');
    await _auth.signOut();
    await GoogleSignIn().signOut(); 
  }
}