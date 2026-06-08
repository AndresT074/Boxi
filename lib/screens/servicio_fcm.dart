import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:googleapis_auth/auth_io.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'servicio_notificaciones.dart';
import 'package:flutter/foundation.dart'; 

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  debugPrint("Notificación manejada por el sistema: ${message.messageId}");
}

class ServicioFCM {
  static const String _projectId = 'boxi-4a68c';

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
    
    // CUANDO LA APP ESTÁ ABIERTA EN PANTALLA:
    FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      await ServicioNotificaciones.inicializar();
      
      // Identificamos de qué trata la notificación
      String tipo = message.data['tipo'] ?? 'nuevo_pedido';

      if (tipo == 'nuevo_pedido') {
        String negocio = message.data['negocio'] ?? 'Tu Negocio';
        String cliente = message.data['cliente'] ?? 'Un cliente';
        await ServicioNotificaciones.mostrarNotificacionPedido(negocio, cliente);
        
      } else if (tipo == 'inactividad') {
        String titulo = message.notification?.title ?? '¡Te extrañamos!';
        String cuerpo = message.notification?.body ?? 'Tu negocio te espera 🚀';
        await ServicioNotificaciones.mostrarNotificacionInactividad(titulo, cuerpo);
      }
    });
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
      
      debugPrint("✅ Token FCM asegurado en Firestore");
      print("MI TOKEN PARA PRUEBAS: $token");
    } catch (e) {
      debugPrint("❌ Error al guardar token en Firestore: $e");
    }
  }

  static Future<String> _getAccessToken() async {
    final jsonStr = await rootBundle.loadString('assets/service_account.json');
    final credentials = ServiceAccountCredentials.fromJson(jsonDecode(jsonStr));
    final scopes = ['https://www.googleapis.com/auth/firebase.messaging'];
    final client = await clientViaServiceAccount(credentials, scopes);
    final token = client.credentials.accessToken.data;
    client.close();
    return token;
  }

  static Future<void> enviarNotificacion({
    required String adminId,
    required String nombreCliente,
  }) async {
    try {
      final userDoc = await FirebaseFirestore.instance
          .collection('usuarios')
          .doc(adminId)
          .get();

      String? fcmToken = userDoc.data()?['fcm_token'];
      if (fcmToken == null) return;

      String nombreNegocio = userDoc.data()?['nombre_negocio'] ?? 'Tu Negocio';
      String accessToken = await _getAccessToken();

      http.post(
        Uri.parse('https://fcm.googleapis.com/v1/projects/$_projectId/messages:send'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $accessToken',
        },
        body: jsonEncode({
          'message': {
            'token': fcmToken,
            // 🔥 SOLUCIÓN CRÍTICA: Android usa este bloque para saltarse el ahorro de batería y sonar
            'notification': {
              'title': '📦 ¡Nuevo Pedido Web!',
              'body': '$nombreCliente te ha enviado un pedido.'
            },
            'data': {
              'negocio': nombreNegocio,
              'cliente': nombreCliente,
              'tipo': 'nuevo_pedido',
            },
            'android': {
              'priority': 'high',
              'notification': {
                'channel_id': 'pedidos_web_urgente',
                'sound': 'default'
              }
            },
          }
        }),
      ).then((response) {
        debugPrint("Estado de FCM: ${response.statusCode}");
      });
    } catch (e) {
      debugPrint('Error FCM V1: $e');
    }
  }
}