import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'servicio_notificaciones.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  debugPrint("Notificación manejada por el sistema: ${message.messageId}");
}

class ServicioFCM {
  static Future<void> inicializar() async {
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    String? token = await FirebaseMessaging.instance.getToken();
    if (token != null) await _guardarToken(token);

    FirebaseMessaging.instance.onTokenRefresh.listen(_guardarToken);

    // 1️⃣ NOTIFICACIONES EN PRIMER PLANO (App Abierta)
    FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      await ServicioNotificaciones.inicializar();
      String tipo = message.data['tipo'] ?? 'nuevo_pedido';

      if (tipo == 'nuevo_pedido') {
        String negocio = message.data['negocio'] ?? 'Tu Negocio';
        String cliente = message.data['cliente'] ?? 'Un cliente';
        await ServicioNotificaciones.mostrarNotificacionPedido(negocio, cliente);
      } else if (tipo == 'inactividad') {
        String titulo = message.notification?.title ?? '¡Te extrañamos!';
        String cuerpo = message.notification?.body ?? 'Tu negocio te espera 🚀';
        await ServicioNotificaciones.mostrarNotificacionInactividad(titulo, cuerpo);
      } else if (tipo == 'punto_fidelidad' || tipo == 'fidelidad_vendedor') {
        String titulo = message.notification?.title ?? message.data['titulo'] ?? '🎁 ¡Punto de Fidelidad!';
        String cuerpo = message.notification?.body ?? message.data['cuerpo'] ?? 'Tienes una nueva actualización en tus puntos.';
        String token = message.data['token'] ?? '';
        await ServicioNotificaciones.mostrarNotificacionFidelidad(titulo, cuerpo, token: token);
      }
    });

    // 2️⃣ NOTIFICACIÓN TOCADA EN SEGUNDO PLANO (App Minimizada)
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) async {
      if (message.data['tipo'] == 'punto_fidelidad' && message.data['token'] != null) {
        String token = message.data['token'];
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('pending_fidelidad_token', token);
        ServicioNotificaciones.onFidelidadTap?.call(token);
      }
    });

    // 3️⃣ NOTIFICACIÓN TOCADA CON APP COMPLETAMENTE CERRADA
    RemoteMessage? initialMessage = await FirebaseMessaging.instance.getInitialMessage();
    if (initialMessage != null && initialMessage.data['tipo'] == 'punto_fidelidad' && initialMessage.data['token'] != null) {
      String token = initialMessage.data['token'];
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('pending_fidelidad_token', token);
    }
  }

  static Future<void> _guardarToken(String token) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    
    try {
      await FirebaseFirestore.instance
          .collection('usuarios')
          .doc(user.uid)
          .set({'fcm_token': token}, SetOptions(merge: true));

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('fcm_token', token);
      
      debugPrint("✅ Token FCM asegurado en Firestore: $token");
    } catch (e) {
      debugPrint("❌ Error al guardar token en Firestore: $e");
    }
  }
}