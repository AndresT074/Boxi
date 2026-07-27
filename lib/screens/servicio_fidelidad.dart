import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

class ServicioFidelidad {
  static final _db = FirebaseFirestore.instance;

  // 🔥 1. VENDEDOR: Crear Token con caducidad de 24 Horas
  static Future<String> crearTokenUnicoNube({
    required String vendorUid,
    required String tarjetaId,
    required String nombreNegocio,
    required String logoPath,
    required String tarjetaTitulo,
    required int metaCompras,
    required String premioDesc,
    required String clienteTelefono,
    dynamic clienteLocalId,
    String? clientUid,
  }) async {
    String vendorHash = vendorUid.length > 4 ? vendorUid.substring(0, 4) : vendorUid;
    String token = "boxi_fidelidad_${DateTime.now().millisecondsSinceEpoch}_$vendorHash".trim();
    final DateTime fechaExpiracion = DateTime.now().add(const Duration(hours: 24));

    await _db.collection('tokens_fidelidad').doc(token).set({
      'token': token,
      'vendorUid': vendorUid,
      'tarjetaId': tarjetaId.toString(),
      'clienteLocalId': clienteLocalId?.toString() ?? '',
      'clientUid': clientUid ?? '',
      'nombreNegocio': nombreNegocio,
      'logoPath': logoPath,
      'tarjetaTitulo': tarjetaTitulo,
      'metaCompras': metaCompras,
      'premioDesc': premioDesc,
      'clienteTelefono': clienteTelefono,
      'usado': false,
      'fechaCreacion': FieldValue.serverTimestamp(),
      'expireAt': Timestamp.fromDate(fechaExpiracion),
    });

    return token;
  }

  // 🔥 2. CLIENTE: Reclamar el punto con destrucción garantizada si es inválido
  static Future<void> reclamarPuntoToken({
    required String token,
    required BuildContext context,
    required Function(Map<String, dynamic> tarjetaCliente, int puntoNuevo) onSuccess,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    
    // 🧹 1. Limpieza preventiva inmediata del celular para no dejar rastro
    await prefs.remove('pending_fidelidad_token');

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      if (context.mounted) {
        _mostrarAlerta(context, "INICIA SESIÓN", "Debes iniciar sesión para guardar tus puntos.", esError: true);
      }
      return;
    }

    String tokenLimpio = token.trim().replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '');

    if (tokenLimpio.isEmpty) {
      if (context.mounted) {
        _mostrarAlerta(context, "TOKEN INVÁLIDO", "El enlace o código no tiene un formato válido.", esError: true);
      }
      return;
    }

    final docRef = _db.collection('tokens_fidelidad').doc(tokenLimpio);

    try {
      final snap = await docRef.get();

      // 🛑 SI EL TOKEN NO EXISTE EN FIRESTORE (Ya fue usado o nunca existió)
      if (!snap.exists) {
        await prefs.remove('pending_fidelidad_token'); // Borrado local
        if (context.mounted) {
          _mostrarAlerta(context, "TOKEN INVÁLIDO", "El enlace o código QR no existe o ya fue utilizado.", esError: true);
        }
        return;
      }

      final data = snap.data() as Map<String, dynamic>;

      // ⏰ 1. SI ESTÁ EXPIRADO (Más de 24 HORAS) -> BORRAR DE FIRESTORE Y CELULAR
      if (data.containsKey('expireAt') && data['expireAt'] != null) {
        Timestamp expireAt = data['expireAt'];
        if (expireAt.toDate().isBefore(DateTime.now())) {
          await docRef.delete(); // 🔥 DESTRUIR DE FIRESTORE
          await prefs.remove('pending_fidelidad_token');
          if (context.mounted) {
            _mostrarAlerta(context, "ENLACE EXPIRADO", "Este código QR o enlace ha caducado (duración máxima 24 horas).", esError: true);
          }
          return;
        }
      }

      // 🛑 2. SI YA FUE MARCADO COMO USADO -> BORRAR DE FIRESTORE Y CELULAR
      if (data['usado'] == true) {
        await docRef.delete(); // 🔥 DESTRUIR DE FIRESTORE
        await prefs.remove('pending_fidelidad_token');
        if (context.mounted) {
          _mostrarAlerta(context, "PUNTO YA USADO", "Este punto de fidelidad ya fue reclamado anteriormente.", esError: true);
        }
        return;
      }

      String vendorUid = data['vendorUid'] ?? '';
      String tarjetaId = data['tarjetaId'] ?? 'general';

      // 🛑 3. SI VIENE CORRUPTO O SIN ID DE VENDEDOR -> BORRAR DE FIRESTORE Y CELULAR
      if (vendorUid.isEmpty) {
        await docRef.delete(); // 🔥 DESTRUIR DE FIRESTORE
        await prefs.remove('pending_fidelidad_token');
        if (context.mounted) {
          _mostrarAlerta(context, "TOKEN INVÁLIDO", "El código no contiene la información del negocio.", esError: true);
        }
        return;
      }

      int meta = ((data['metaCompras'] ?? 10) as num).toInt();

      // Guardar en la cuenta del cliente
      DocumentReference miTarjetaRef = _db
          .collection('usuarios')
          .doc(user.uid)
          .collection('tarjetas_acumuladas')
          .doc(vendorUid);

      final tarjetaSnap = await miTarjetaRef.get();
      int puntosActuales = 1;
      int completadas = 0;

      if (tarjetaSnap.exists) {
        var tData = tarjetaSnap.data() as Map<String, dynamic>;
        int ptsAntiguos = ((tData['puntosActuales'] ?? 0) as num).toInt();
        completadas = ((tData['completadasTotales'] ?? 0) as num).toInt();

        if (ptsAntiguos >= meta) {
          // Si la tarjeta anterior ya estaba llena, el nuevo token inicia otra tarjeta en 1
          puntosActuales = 1;
        } else {
          puntosActuales = ptsAntiguos + 1;
          if (puntosActuales >= meta) {
            completadas++; // Completa la tarjeta actual
          }
        }
      }

      Map<String, dynamic> datosTarjetaCliente = {
        'vendorUid': vendorUid,
        'tarjetaId': tarjetaId,
        'nombreNegocio': data['nombreNegocio'] ?? 'Negocio',
        'logoPath': data['logoPath'] ?? '',
        'tarjetaTitulo': data['tarjetaTitulo'] ?? 'Tarjeta Fidelidad',
        'metaCompras': meta,
        'premioDesc': data['premioDesc'] ?? '',
        'puntosActuales': puntosActuales,
        'completadasTotales': completadas,
        'ultimaModificacion': FieldValue.serverTimestamp(),
      };

      await miTarjetaRef.set(datosTarjetaCliente, SetOptions(merge: true));

      // Vincular en la cuenta del vendedor en Firestore
      await _db
          .collection('usuarios')
          .doc(vendorUid)
          .collection('mis_tarjetas_creadas')
          .doc(tarjetaId)
          .collection('clientes')
          .doc(user.uid)
          .set({
        'clientUid': user.uid,
        'clienteLocalId': data['clienteLocalId'] ?? '',
        'clienteEmail': user.email ?? '',
        'clienteTelefono': data['clienteTelefono'] ?? '',
        'puntosActuales': puntosActuales,
        'completadasTotales': completadas,
        'ultimaModificacion': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // 🔥 SI EL VENDEDOR LO RECLAMA ÉL MISMO (Para un cliente con iPhone), actualizar SQLite local
      String clienteLocalIdStr = data['clienteLocalId']?.toString() ?? '';
      if (clienteLocalIdStr.isNotEmpty) {
        try {
          final dbLocal = await DBHelper.instance.database;
          int cId = int.tryParse(clienteLocalIdStr) ?? 0;
          int tId = int.tryParse(tarjetaId) ?? 0;
          if (cId > 0 && tId > 0) {
            await dbLocal.insert('puntos_clientes', {
              'cliente_id': cId,
              'tarjeta_id': tId,
              'puntos_actuales': puntosActuales,
              'completadas_totales': completadas,
              'ultima_modificacion': DateTime.now().toIso8601String(),
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        } catch (e) {
          debugPrint("Error actualizando SQLite local en autovinculacion: $e");
        }
      }

      // 🔥 4. RECLAMO EXITOSO -> DESTRUIR TOKEN DE FIRESTORE Y CELULAR
      await docRef.delete();
      await prefs.remove('pending_fidelidad_token');

      // Notificar al vendedor por FCM
      notificarVendedorPuntoReclamado(
        vendorUid: vendorUid,
        nombreCliente: user.email ?? 'Un cliente',
        nombreNegocio: data['nombreNegocio'] ?? 'Tu negocio',
      );

      onSuccess(datosTarjetaCliente, puntosActuales);

    } catch (e) {
      // 🧹 Si ocurre un error inesperado, intenta destruir de Firestore y limpia el celular
      try { await docRef.delete(); } catch (_) {}
      await prefs.remove('pending_fidelidad_token');

      if (context.mounted) {
        _mostrarAlerta(context, "ERROR", "No se pudo reclamar el punto: $e", esError: true);
      }
    }
  }

  // 🔥 NOTIFICAR AL VENDEDOR
  static Future<void> notificarVendedorPuntoReclamado({
    required String vendorUid,
    required String nombreCliente,
    required String nombreNegocio,
  }) async {
    try {
      await http.post(
        Uri.parse('https://boxi-api.vercel.app/api/notificar-fidelidad'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'targetUid': vendorUid,
          'titulo': '🎁 ¡Punto de Fidelidad Reclamado!',
          'cuerpo': '$nombreCliente ha reclamado un punto en $nombreNegocio.',
          'tipo': 'fidelidad_vendedor',
        }),
      );
    } catch (e) {
      debugPrint("Error enviando notificación al vendedor: $e");
    }
  }

  // 🔥 NOTIFICAR AL CLIENTE (PUNTO OTORGADO POR COMPRA / AUTOMÁTICO)
  static Future<void> notificarClientePuntoOtorgado({
    required String clientUid,
    required String nombreNegocio,
    required int puntosActuales,
    required int meta,
  }) async {
    try {
      await http.post(
        Uri.parse('https://boxi-api.vercel.app/api/notificar-fidelidad'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'targetUid': clientUid,
          'titulo': '🎉 ¡Punto de Fidelidad Recibido!',
          'cuerpo': '¡$nombreNegocio te ha sumado un punto! Tienes $puntosActuales de $meta puntos.',
          'tipo': 'punto_fidelidad',
        }),
      );
    } catch (e) {
      debugPrint("Error enviando notificación al cliente: $e");
    }
  }

  static void _mostrarAlerta(BuildContext context, String titulo, String msg, {bool esError = false}) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(titulo, style: TextStyle(color: esError ? Colors.redAccent : Colors.green, fontWeight: FontWeight.bold)),
        content: Text(msg),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: esError ? Colors.redAccent : Colors.green),
            onPressed: () => Navigator.pop(ctx),
            child: const Text("ENTENDIDO", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  static Future<void> eliminarTarjetaAcumuladaCliente({
    required String vendorUid,
    required String tarjetaId,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      await _db
          .collection('usuarios')
          .doc(user.uid)
          .collection('tarjetas_acumuladas')
          .doc(vendorUid)
          .delete();

      await _db
          .collection('usuarios')
          .doc(vendorUid)
          .collection('mis_tarjetas_creadas')
          .doc(tarjetaId)
          .collection('clientes')
          .doc(user.uid)
          .delete();

    } catch (e) {
      debugPrint("Error eliminando tarjeta acumulada: $e");
    }
  }
}