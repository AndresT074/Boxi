import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter/services.dart';
import '../database/db_helper.dart';
import 'pantalla_premium.dart';
import 'servicio_fidelidad.dart';
import 'servicio_anuncios.dart';
import 'dart:convert';
import 'package:firebase_database/firebase_database.dart';
import 'servicio_nube.dart';
import 'package:url_launcher/url_launcher.dart';

class PantallaFidelidad extends StatefulWidget {
  final String? tokenParaReclamarDirecto;
  const PantallaFidelidad({super.key, this.tokenParaReclamarDirecto});

  @override
  State<PantallaFidelidad> createState() => _PantallaFidelidadState();
}

class _PantallaFidelidadState extends State<PantallaFidelidad> {
  bool _esPremium = false;
  List<Map<String, dynamic>> _misTarjetasComoVendedor = [];
  List<Map<String, dynamic>> _misTarjetasComoCliente = [];
  String _nombreNegocio = "MI NEGOCIO";
  String _logoPath = "";
  bool _cargandoDatos = true;

  @override
  void initState() {
    super.initState();
    _cargarDatosBD();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (widget.tokenParaReclamarDirecto != null && widget.tokenParaReclamarDirecto!.isNotEmpty) {
        _ejecutarReclamoDirecto(widget.tokenParaReclamarDirecto!);
      }
    });
  }

  Future<void> _cargarDatosBD() async {
    final prefs = await SharedPreferences.getInstance();
    final db = await DBHelper.instance.database;
    final user = FirebaseAuth.instance.currentUser;

    // ⚡ 1. Carga instantánea local desde SQLite (0s)
    final tarjetasRes = await db.query('tarjetas_fidelidad', orderBy: 'id DESC');

    // 2. CLIENTE: Cargar tarjetas acumuladas de otros negocios
    List<Map<String, dynamic>> misTarjetasClienteNube = [];
    if (user != null) {
      try {
        final snap = await FirebaseFirestore.instance
            .collection('usuarios')
            .doc(user.uid)
            .collection('tarjetas_acumuladas')
            .get();
        misTarjetasClienteNube = snap.docs.map((d) => d.data()).toList();
      } catch (e) {
        debugPrint("Error cargando tarjetas acumuladas de cliente: $e");
      }
    }

    if (mounted) {
      setState(() {
        _esPremium = prefs.getBool('es_premium') ?? false;
        _nombreNegocio = prefs.getString('nombre_negocio') ?? "MI NEGOCIO";
        _logoPath = prefs.getString('logo_path') ?? "";
        _misTarjetasComoVendedor = List<Map<String, dynamic>>.from(tarjetasRes);
        _misTarjetasComoCliente = misTarjetasClienteNube;
        _cargandoDatos = false;
      });
    }

    // 🧹 3. VERIFICACIÓN EN SEGUNDO PLANO VÍA REALTIME DATABASE (0 LECTURAS FIRESTORE)
    if (user != null && _esPremium && await ServicioNube.tieneInternet()) {
      try {
        final ref = FirebaseDatabase.instance.ref("datos_privados/${user.uid}/tarjetas_fidelidad");
        final snap = await ref.get();

        if (snap.exists) {
          final raw = snap.value;
          List<int> idsRTDB = [];
          if (raw is List) {
            for (var item in raw) {
              if (item != null && item['id'] != null) idsRTDB.add((item['id'] as num).toInt());
            }
          }

          final tarjetasLocales = await db.query('tarjetas_fidelidad', columns: ['id']);
          bool huboBorrados = false;

          for (var t in tarjetasLocales) {
            int localId = t['id'] as int;
            if (!idsRTDB.contains(localId) && idsRTDB.isNotEmpty) {
              await db.delete('tarjetas_fidelidad', where: 'id = ?', whereArgs: [localId]);
              huboBorrados = true;
            }
          }

          if (huboBorrados) {
            final tarjetasLimpias = await db.query('tarjetas_fidelidad', orderBy: 'id DESC');
            if (mounted) {
              setState(() {
                _misTarjetasComoVendedor = List<Map<String, dynamic>>.from(tarjetasLimpias);
              });
            }
          }
        }
      } catch (e) {
        debugPrint("Error comprobando borrados en RTDB: $e");
      }
    }
  }

  void _ejecutarReclamoDirecto(String token) {
    ServicioFidelidad.reclamarPuntoToken(
      token: token,
      context: context,
      onSuccess: (negocioData, puntoNuevo) {
        _cargarDatosBD();
        _mostrarAnimacionEstampadoX(negocioData, puntoNuevo);
      },
    );
  }

  // 🎬 ANIMACIÓN DE ESTAMPADO DE LA "X" MEJORADA (Más lenta, grande y vistosa)
  void _mostrarAnimacionEstampadoX(Map<String, dynamic> tarjeta, int puntoNuevo) {
    int meta = ((tarjeta['metaCompras'] ?? 10) as num).toInt();
    String nomNegocio = tarjeta['nombreNegocio'] ?? 'Negocio';
    String premio = tarjeta['premioDesc'] ?? tarjeta['titulo'] ?? 'Recompensa';
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          backgroundColor: Theme.of(context).cardColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(25)),
          title: Text("¡Punto Reclamado en $nomNegocio!", textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text("Por $meta compras obtienes $premio", style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1)), textAlign: TextAlign.center),
              const SizedBox(height: 20),

              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 5,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                ),
                itemCount: meta,
                itemBuilder: (context, index) {
                  bool tieneSello = (index + 1) <= puntoNuevo;
                  bool esElNuevoSello = (index + 1) == puntoNuevo;

                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 800),
                    curve: Curves.elasticOut,
                    decoration: BoxDecoration(
                      color: tieneSello ? Colors.green.withOpacity(0.15) : (isOscuro ? Colors.white10 : Colors.grey.shade100),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: tieneSello ? Colors.green : Colors.grey.shade300, width: tieneSello ? 2 : 1),
                    ),
                    child: Center(
                      child: tieneSello
                          ? TweenAnimationBuilder<double>(
                              duration: const Duration(milliseconds: 1200), // 👈 Animación de 1.2s muy vistosa
                              tween: Tween(begin: 0.0, end: 1.0),
                              curve: Curves.elasticOut, // 👈 Efecto rebote de sello real
                              builder: (context, scale, child) {
                                return Transform.scale(
                                  scale: esElNuevoSello ? (0.4 + scale * 0.8) : 1.0,
                                  child: const Text("❌", style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                                );
                              },
                            )
                          : Text("${index + 1}", style: TextStyle(color: Colors.grey.shade400, fontSize: 11)),
                    ),
                  );
                },
              ),
              const SizedBox(height: 20),
              const Text("🎉 ¡Punto reclamado con éxito!", style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 14)),
            ],
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0D47A1), foregroundColor: Colors.white, minimumSize: const Size(double.infinity, 45)),
              onPressed: () {
                Navigator.pop(ctx);
                if (!_esPremium) ServicioAnuncios.mostrarAnuncioIntersticial(() {});
              },
              child: const Text("ACEPTAR", style: TextStyle(fontWeight: FontWeight.bold)),
            )
          ],
        ),
      ),
    );
  }

  // MODAL PARA INGRESAR LINK / ESCANEAR QR
  void _mostrarModalIngresarLink() {
    TextEditingController linkCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.qr_code_scanner_rounded, color: Colors.blueAccent),
            SizedBox(width: 10),
            Text("Reclamar Punto", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Pega el enlace o código que te dio el vendedor para reclamar tu punto:", style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 15),
            TextField(
              controller: linkCtrl,
              decoration: const InputDecoration(
                hintText: "https://boxi-catalogo.web.app/reclamar?token=...",
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.link),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
            onPressed: () {
              String texto = linkCtrl.text.trim();
              if (texto.isEmpty) return;
              Navigator.pop(ctx);

              String token = texto;
              if (texto.contains("token=")) {
                token = texto.split("token=").last.split("&").first;
              }
              _ejecutarReclamoDirecto(token);
            },
            child: const Text("RECLAMAR"),
          ),
        ],
      ),
    );
  }

  void _mostrarModalCrearTarjeta({Map<String, dynamic>? tarjetaAEditar}) {
    if (!_esPremium) {
      _mostrarAlertaPremium();
      return;
    }

    final metaCtrl = TextEditingController(text: tarjetaAEditar != null ? tarjetaAEditar['meta_compras'].toString() : "");
    final premioCtrl = TextEditingController(text: tarjetaAEditar != null ? (tarjetaAEditar['premio_descripcion'] ?? tarjetaAEditar['titulo']) : "");

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(tarjetaAEditar == null ? "Nueva Tarjeta de Fidelidad" : "Editar Tarjeta", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: premioCtrl, decoration: const InputDecoration(labelText: "Recompensa (ej: Audífonos)", border: OutlineInputBorder())),
              const SizedBox(height: 15),
              TextField(controller: metaCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: "Meta de Compras (ej: 10)", border: OutlineInputBorder())),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0D47A1), foregroundColor: Colors.white),
            onPressed: () async {
              String premio = premioCtrl.text.trim();
              int meta = int.tryParse(metaCtrl.text.trim()) ?? 0;

              if (premio.isEmpty || meta <= 0) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("⚠️ Ingresa la recompensa y una meta válida.")));
                return;
              }

              Navigator.pop(ctx);
              final db = await DBHelper.instance.database;
              Map<String, dynamic> tarjetaMap = {
                'titulo': premio,
                'meta_compras': meta,
                'premio_descripcion': premio,
                'activa': tarjetaAEditar != null ? tarjetaAEditar['activa'] : 1,
                'ultima_modificacion': DateTime.now().toIso8601String(),
              };

              int idTarjetaInsertada;
              if (tarjetaAEditar == null) {
                idTarjetaInsertada = await db.insert('tarjetas_fidelidad', tarjetaMap);
              } else {
                idTarjetaInsertada = tarjetaAEditar['id'];
                await db.update('tarjetas_fidelidad', tarjetaMap, where: 'id = ?', whereArgs: [idTarjetaInsertada]);
              }

              final user = FirebaseAuth.instance.currentUser;
              if (user != null) {
                Map<String, dynamic> datosNube = {
                  'tarjetaId': idTarjetaInsertada.toString(),
                  'titulo': premio,
                  'metaCompras': meta,
                  'premioDesc': premio,
                  'activa': tarjetaAEditar != null ? tarjetaAEditar['activa'] : 1,
                };

                if (await ServicioNube.tieneInternet()) {
                  await FirebaseFirestore.instance
                      .collection('usuarios')
                      .doc(user.uid)
                      .collection('mis_tarjetas_creadas')
                      .doc(idTarjetaInsertada.toString())
                      .set({
                    ...datosNube,
                    'ultimaModificacion': FieldValue.serverTimestamp(),
                  }, SetOptions(merge: true));
                } else {
                  await db.insert('operaciones_pendientes', {
                    'tabla': 'mis_tarjetas_creadas',
                    'operacion': 'set',
                    'doc_id': idTarjetaInsertada.toString(),
                    'datos_json': jsonEncode(datosNube),
                    'fecha_creacion': DateTime.now().toIso8601String(),
                  }, conflictAlgorithm: ConflictAlgorithm.replace);
                }

                await ServicioNube.respaldarDatosPrivadosRTDB();
              }

              _cargarDatosBD();
            },
            child: const Text("GUARDAR"),
          ),
        ],
      ),
    );
  }

  Future<void> _mostrarListadoClientesParaPuntos(Map<String, dynamic> tarjetaData) async {
    final db = await DBHelper.instance.database;
    final user = FirebaseAuth.instance.currentUser;
    String tarjetaIdStr = tarjetaData['id'].toString();

    // 1. Obtener clientes de Firestore
    List<QueryDocumentSnapshot<Map<String, dynamic>>> docsCloud = [];
    bool cloudDisponible = false;

    if (user != null && await ServicioNube.tieneInternet()) {
      try {
        final cloudSnap = await FirebaseFirestore.instance
            .collection('usuarios')
            .doc(user.uid)
            .collection('mis_tarjetas_creadas')
            .doc(tarjetaIdStr)
            .collection('clientes')
            .get();
        docsCloud = cloudSnap.docs;
        cloudDisponible = true;
      } catch (e) {
        debugPrint("Error leyendo clientes cloud: $e");
      }
    }

    // Mapa de puntos reales de la nube
    Map<String, int> puntosCloudPorLocalId = {};
    for (var doc in docsCloud) {
      final data = doc.data();
      String locId = data['clienteLocalId']?.toString() ?? '';
      int ptsCloud = ((data['puntosActuales'] ?? 0) as num).toInt();
      if (locId.isNotEmpty) {
        puntosCloudPorLocalId[locId] = ptsCloud;
      }
    }

    // 🔥 2. SANEAMIENTO: Si la nube respondió, eliminar registros locales de clientes que eliminaron la tarjeta
    if (cloudDisponible) {
      final puntosLocalEnBD = await db.query('puntos_clientes', where: 'tarjeta_id = ?', whereArgs: [tarjetaData['id']]);
      Batch batchLimpieza = db.batch();
      bool huboLimpieza = false;

      for (var p in puntosLocalEnBD) {
        String cLocalId = p['cliente_id'].toString();
        // Si el cliente tenía puntos locales pero YA NO existe en la nube -> Borrar de SQLite
        if (!puntosCloudPorLocalId.containsKey(cLocalId)) {
          batchLimpieza.delete('puntos_clientes', where: 'cliente_id = ? AND tarjeta_id = ?', whereArgs: [p['cliente_id'], tarjetaData['id']]);
          huboLimpieza = true;
        }
      }

      if (huboLimpieza) {
        await batchLimpieza.commit(noResult: true);
      }
    }

    // 3. Obtener clientes locales actualizados
    final clientesDB = await db.query('clientes');
    final pedidosDB = await db.rawQuery("SELECT DISTINCT cliente_nombre_snapshot as nombre, cliente_id as id FROM pedidos WHERE cliente_nombre_snapshot IS NOT NULL AND cliente_nombre_snapshot != ''");
    final puntosLocal = await db.query('puntos_clientes', where: 'tarjeta_id = ?', whereArgs: [tarjetaData['id']]);

    Map<int, int> mapaPuntosLocal = {};
    for (var p in puntosLocal) {
      mapaPuntosLocal[p['cliente_id'] as int] = p['puntos_actuales'] as int;
    }

    // 4. MAPA UNIFICADO
    Map<String, Map<String, dynamic>> clientesUnificados = {};

    for (var c in clientesDB) {
      String idKey = c['id'].toString();
      String nom = (c['nombre_completo'] ?? '').toString().trim();
      int pts = mapaPuntosLocal[c['id'] as int] ?? 0;

      if (nom.isNotEmpty) {
        clientesUnificados[idKey] = {
          'id': c['id'],
          'clienteLocalId': c['id'].toString(),
          'nombre_completo': nom,
          'telefono': c['telefono'] ?? '',
          'puntos': pts,
        };
      }
    }

    for (var p in pedidosDB) {
      String nom = (p['nombre'] ?? '').toString().trim();
      String pIdKey = (p['id'] ?? DateTime.now().millisecondsSinceEpoch).toString();
      if (nom.isNotEmpty && !clientesUnificados.values.any((item) => item['nombre_completo'].toString().toLowerCase() == nom.toLowerCase())) {
        clientesUnificados[pIdKey] = {
          'id': p['id'] ?? DateTime.now().millisecondsSinceEpoch,
          'clienteLocalId': pIdKey,
          'nombre_completo': nom,
          'telefono': '',
          'puntos': 0,
        };
      }
    }

    // Fusionar con datos de la nube
    for (var doc in docsCloud) {
      final data = doc.data();
      String cUid = doc.id;
      String locId = data['clienteLocalId']?.toString() ?? '';
      String email = data['clienteEmail'] ?? '';
      int ptsCloud = ((data['puntosActuales'] ?? 0) as num).toInt();

      if (locId.isNotEmpty && clientesUnificados.containsKey(locId)) {
        var local = clientesUnificados[locId]!;
        local['puntos'] = ptsCloud; // La nube manda
        local['clientUid'] = cUid;
        if (email.isNotEmpty && !local['nombre_completo'].toString().contains(email)) {
          local['nombre_completo'] = "${local['nombre_completo']} ($email)";
        }
      } else {
        clientesUnificados[cUid] = {
          'id': cUid,
          'clientUid': cUid,
          'nombre_completo': email.isNotEmpty ? email : 'Cliente App',
          'telefono': data['clienteTelefono'] ?? '',
          'puntos': ptsCloud,
        };
      }
    }

    List<Map<String, dynamic>> activos = [];
    List<Map<String, dynamic>> inactivos = [];

    clientesUnificados.forEach((key, val) {
      if ((val['puntos'] as int) > 0) {
        activos.add(val);
      } else {
        inactivos.add(val);
      }
    });

    activos.sort((a, b) => (b['puntos'] as int).compareTo(a['puntos'] as int));
    inactivos.sort((a, b) => (a['nombre_completo'] as String).compareTo(b['nombre_completo'] as String));

    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DefaultTabController(
        length: 2,
        child: Container(
          height: MediaQuery.of(ctx).size.height * 0.75,
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(25)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 12),
              Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey, borderRadius: BorderRadius.circular(2))),
              const SizedBox(height: 15),
              Text("Clientes para: ${tarjetaData['titulo']}", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1))),
              const SizedBox(height: 10),
              TabBar(
                labelColor: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1),
                unselectedLabelColor: Colors.grey,
                indicatorColor: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1),
                tabs: [
                  Tab(text: "Activos (${activos.length})"),
                  Tab(text: "Inactivos (${inactivos.length})"),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _buildListaClientesSelect(activos, tarjetaData),
                    _buildListaClientesSelect(inactivos, tarjetaData),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildListaClientesSelect(List<Map<String, dynamic>> lista, Map<String, dynamic> tarjetaData) {
    if (lista.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(20.0),
          child: Text("No hay clientes en esta sección.", textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(15),
      itemCount: lista.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (ctx, i) {
        var c = lista[i];
        return ListTile(
          leading: const CircleAvatar(backgroundColor: Colors.blueAccent, child: Icon(Icons.person, color: Colors.white, size: 20)),
          title: Text(c['nombre_completo'], style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
          subtitle: Text("Puntos: ${c['puntos']} / ${tarjetaData['meta_compras']}"),
          trailing: ElevatedButton.icon(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white, elevation: 0),
            icon: const Icon(Icons.add_circle, size: 16),
            label: const Text("Dar Punto"),
            onPressed: () async {
              Navigator.pop(context);
              final user = FirebaseAuth.instance.currentUser;
              String token = await ServicioFidelidad.crearTokenUnicoNube(
                vendorUid: user?.uid ?? 'anon',
                tarjetaId: tarjetaData['id'].toString(),
                clienteLocalId: c['id'],
                nombreNegocio: _nombreNegocio,
                logoPath: _logoPath,
                tarjetaTitulo: tarjetaData['titulo'] ?? 'Tarjeta Fidelidad',
                metaCompras: tarjetaData['meta_compras'],
                premioDesc: tarjetaData['premio_descripcion'] ?? '',
                clienteTelefono: c['telefono']?.toString() ?? '',
              );
              _generarQrOLinkUnico(token, c['nombre_completo']);
            },
          ),
        );
      },
    );
  }

  // GENERADOR DE QR / LINK
  void _generarQrOLinkUnico(String tokenUnico, String nombreCliente) {
    String enlaceUnico = "https://boxi-catalogo.web.app/reclamar?token=$tokenUnico";

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).cardColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text("Punto para $nombreCliente", style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Muestra este código QR al cliente o envíale el enlace de uso único para que lo reclame en su app:", style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(15)),
              child: SizedBox(
                width: 180, height: 180,
                child: QrImageView(data: enlaceUnico, version: QrVersions.auto, gapless: false),
              ),
            ),
            const SizedBox(height: 20),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0D47A1), foregroundColor: Colors.white),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: enlaceUnico));
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Enlace copiado al portapapeles 📋")));
              },
              icon: const Icon(Icons.copy, size: 16),
              label: const Text("Copiar Enlace Único"),
            )
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CERRAR"))],
      ),
    );
  }

  // 🔥 RECLAMAR RECOMPENSA VÍA WHATSAPP
  Future<void> _reclamarRecompensaWhatsApp(Map<String, dynamic> tarjeta) async {
    String vendorUid = tarjeta['vendorUid'] ?? '';
    String nomNegocio = tarjeta['nombreNegocio'] ?? 'Negocio';
    String premio = tarjeta['premioDesc'] ?? tarjeta['titulo'] ?? 'Recompensa';
    int meta = ((tarjeta['metaCompras'] ?? 10) as num).toInt();

    final user = FirebaseAuth.instance.currentUser;
    String emailCliente = user?.email ?? 'Cliente registrado';

    String telefonoVendedor = "";

    // 1. Consultar el número de WhatsApp del vendedor en Firestore
    if (vendorUid.isNotEmpty) {
      try {
        final vendorDoc = await FirebaseFirestore.instance.collection('usuarios').doc(vendorUid).get();
        if (vendorDoc.exists) {
          telefonoVendedor = vendorDoc.data()?['whatsapp_admin'] ?? vendorDoc.data()?['telefono'] ?? '';
        }
      } catch (e) {
        debugPrint("Error buscando teléfono del vendedor: $e");
      }
    }

    if (telefonoVendedor.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("⚠️ El negocio aún no ha configurado un número de WhatsApp."))
        );
      }
      return;
    }

    String numClean = telefonoVendedor.replaceAll(RegExp(r'\D'), '');
    String mensaje = "¡Hola *$nomNegocio*! 👋 Completé los *$meta puntos* de mi tarjeta para el premio: *$premio* 🎁.\n\nMi cuenta en la app es: *$emailCliente*\n\n¿Cómo puedo reclamar mi recompensa? ¡Muchas gracias! 🙌";

    String urlWa = "https://wa.me/$numClean?text=${Uri.encodeComponent(mensaje)}";
    if (await canLaunchUrl(Uri.parse(urlWa))) {
      await launchUrl(Uri.parse(urlWa), mode: LaunchMode.externalApplication);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("No se pudo abrir WhatsApp en este dispositivo."))
        );
      }
    }
  }

  void _mostrarAlertaPremium() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0D1B2A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Colors.orangeAccent, width: 1)),
        title: const Row(children: [Icon(Icons.stars, color: Colors.orangeAccent), SizedBox(width: 10), Text("Función Exclusiva PRO", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold))]),
        content: const Text("Hazte Premium para acceder al sistema de tarjetas de fidelidad y premiar a tus clientes con puntos y códigos QR.", style: TextStyle(color: Colors.white70, fontSize: 13)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR", style: TextStyle(color: Colors.white38))),
          ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.orangeAccent), onPressed: () { Navigator.pop(ctx); Navigator.push(context, MaterialPageRoute(builder: (_) => const PantallaPremium())); }, child: const Text("ACCEDER A PRO", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;

    if (_cargandoDatos) {
      return Scaffold(
        backgroundColor: isOscuro ? const Color(0xFF0A0A0F) : const Color(0xFFF2F4F7),
        appBar: AppBar(title: const Text('Premios Fidelidad'), backgroundColor: isOscuro ? const Color(0xFF0D1B2A) : const Color(0xFF0D47A1)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: isOscuro ? const Color(0xFF0A0A0F) : const Color(0xFFF2F4F7),
      appBar: AppBar(
        title: const Text('Premios Fidelidad', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        backgroundColor: isOscuro ? const Color(0xFF0D1B2A) : const Color(0xFF0D47A1),
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            // ==========================================
            // SECCIÓN 1 (ARRIBA): MIS PREMIOS ACUMULADOS (CLIENTE)
            // ==========================================
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Expanded(
                  child: Text(
                    "MIS PREMIOS ACUMULADOS",
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.blueGrey, letterSpacing: 0.5),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton.icon(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: _mostrarModalIngresarLink,
                  icon: const Icon(Icons.qr_code_scanner_rounded, size: 14),
                  label: const Text("Ingresar Link / QR", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 10),

            if (_misTarjetasComoCliente.isEmpty)
              Container(
                width: double.infinity, padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(color: Theme.of(context).cardColor, borderRadius: BorderRadius.circular(20), border: Border.all(color: isOscuro ? Colors.white10 : Colors.black12)),
                child: Column(
                  children: [
                    Icon(Icons.style_outlined, size: 40, color: Colors.grey.shade400),
                    const SizedBox(height: 10),
                    const Text("No tienes tarjetas acumuladas", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    const SizedBox(height: 4),
                    const Text("Escanea el QR de tus negocios favoritos para acumular puntos.", textAlign: TextAlign.center, style: TextStyle(color: Colors.grey, fontSize: 11)),
                  ],
                ),
              )
            else
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _misTarjetasComoCliente.length,
                itemBuilder: (ctx, i) {
                  var item = _misTarjetasComoCliente[i];
                  String logo = item['logoPath'] ?? '';
                  String nomNegocio = item['nombreNegocio'] ?? 'Negocio';
                  String premio = item['premioDesc'] ?? 'Premio Especial';
                  int pts = ((item['puntosActuales'] ?? 0) as num).toInt();
                  int meta = ((item['metaCompras'] ?? 10) as num).toInt();
                  bool metaAlcanzada = pts >= meta;

                  return Card(
                    color: Theme.of(context).cardColor,
                    margin: const EdgeInsets.only(bottom: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                      side: metaAlcanzada 
                          ? const BorderSide(color: Color(0xFF25D366), width: 2)
                          : BorderSide.none,
                    ),
                    elevation: 2,
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Column(
                        children: [
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: CircleAvatar(
                              radius: 26,
                              backgroundColor: isOscuro ? Colors.white10 : Colors.grey.shade200,
                              backgroundImage: logo.isNotEmpty
                                  ? (logo.startsWith('http') ? NetworkImage(logo) : FileImage(File(logo)) as ImageProvider)
                                  : null,
                              child: logo.isEmpty ? const Icon(Icons.store, color: Color(0xFF0D47A1)) : null,
                            ),
                            title: Text(nomNegocio, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 4),
                                Text("Por $meta compras obtienes $premio", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1))),
                              ],
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: (metaAlcanzada ? Colors.orange : Colors.green).withOpacity(0.15), 
                                    borderRadius: BorderRadius.circular(12)
                                  ),
                                  child: Text(
                                    metaAlcanzada ? "¡COMPLETADO! 🎉" : "$pts / $meta pts", 
                                    style: TextStyle(color: metaAlcanzada ? Colors.orange.shade900 : Colors.green, fontWeight: FontWeight.w900, fontSize: 11)
                                  ),
                                ),
                                PopupMenuButton<String>(
                                  icon: const Icon(Icons.more_vert, size: 20, color: Colors.grey),
                                  onSelected: (val) async {
                                    if (val == 'delete') {
                                      bool confirm = await showDialog(
                                        context: context,
                                        builder: (ctx) => AlertDialog(
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                          title: const Text("¿Eliminar Tarjeta?", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.redAccent, fontSize: 16)),
                                          content: Text("¿Estás seguro de que deseas eliminar la tarjeta de \"$nomNegocio\"?\n\nPerderás tus $pts puntos acumulados y volverás a ser un cliente inactivo para este negocio."),
                                          actions: [
                                            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("CANCELAR")),
                                            ElevatedButton(
                                              style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                                              onPressed: () => Navigator.pop(ctx, true),
                                              child: const Text("ELIMINAR", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                            ),
                                          ],
                                        ),
                                      ) ?? false;

                                      if (!confirm) return;

                                      String vendorUid = item['vendorUid'] ?? '';
                                      String tarjetaId = item['tarjetaId'] ?? 'general';

                                      await ServicioFidelidad.eliminarTarjetaAcumuladaCliente(
                                        vendorUid: vendorUid,
                                        tarjetaId: tarjetaId,
                                      );

                                      _cargarDatosBD();
                                    }
                                  },
                                  itemBuilder: (ctx) => [
                                    const PopupMenuItem(
                                      value: 'delete',
                                      child: Row(children: [Icon(Icons.delete_outline, size: 16, color: Colors.red), SizedBox(width: 8), Text("Eliminar Tarjeta", style: TextStyle(color: Colors.red, fontSize: 13))]),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            onTap: () => _mostrarAnimacionEstampadoX(item, pts),
                          ),

                          if (metaAlcanzada) ...[
                            const SizedBox(height: 10),
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF25D366),
                                foregroundColor: Colors.white,
                                minimumSize: const Size(double.infinity, 44),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                elevation: 3,
                              ),
                              onPressed: () => _reclamarRecompensaWhatsApp(item),
                              icon: const Icon(Icons.card_giftcard_rounded, size: 20),
                              label: const Text(
                                "🎁 ¡RECLAMAR RECOMPENSA!", 
                                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 13, letterSpacing: 0.5)
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  );
                },
              ),

            const SizedBox(height: 30),

            // ==========================================
            // SECCIÓN 2 (ABAJO): SISTEMA DE FIDELIZACIÓN (MI NEGOCIO)
            // ==========================================
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Expanded(
                  child: Text(
                    "SISTEMA DE FIDELIZACIÓN (MI NEGOCIO)",
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.blueGrey, letterSpacing: 1),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _mostrarModalCrearTarjeta(),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text("Nueva", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
            const SizedBox(height: 10),

            if (_misTarjetasComoVendedor.isEmpty)
              Container(
                width: double.infinity, padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(color: Theme.of(context).cardColor, borderRadius: BorderRadius.circular(20), border: Border.all(color: isOscuro ? Colors.white10 : Colors.black12)),
                child: Column(
                  children: [
                    Icon(Icons.card_giftcard_outlined, size: 40, color: Colors.grey.shade400),
                    const SizedBox(height: 10),
                    const Text("No has creado tarjetas para tus clientes", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    const SizedBox(height: 15),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0D47A1), foregroundColor: Colors.white),
                      onPressed: () => _mostrarModalCrearTarjeta(),
                      child: const Text("Crear Primera Tarjeta"),
                    ),
                  ],
                ),
              )
            else
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _misTarjetasComoVendedor.length,
                itemBuilder: (ctx, i) {
                  var t = _misTarjetasComoVendedor[i];
                  bool esActiva = t['activa'] == 1;

                  return Card(
                    color: Theme.of(context).cardColor,
                    margin: const EdgeInsets.only(bottom: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    child: ListTile(
                      onTap: () {
                        if (!esActiva) {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Esta tarjeta está inactiva.")));
                          return;
                        }
                        _mostrarListadoClientesParaPuntos(t); // Tocar la tarjeta despliega tus clientes
                      },
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      title: Text(t['titulo'] ?? 'Tarjeta', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: isOscuro ? Colors.white : Colors.black87)),
                      subtitle: Text("Por ${t['meta_compras']} compras obtienes ${t['premio_descripcion'] ?? t['titulo']}", style: TextStyle(fontSize: 11, color: isOscuro ? Colors.white60 : Colors.black54)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(color: (esActiva ? Colors.green : Colors.grey).withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                            child: Text(esActiva ? "Activa" : "Inactiva", style: TextStyle(color: esActiva ? Colors.green : Colors.grey, fontWeight: FontWeight.bold, fontSize: 10)),
                          ),
                          PopupMenuButton<String>(
                            icon: const Icon(Icons.more_vert, size: 20, color: Colors.grey),
                            onSelected: (val) async {
                              final db = await DBHelper.instance.database;
                              final user = FirebaseAuth.instance.currentUser;
                              String tarjetaIdStr = t['id'].toString();
                              String tituloTarj = t['titulo'] ?? 'Tarjeta';

                              if (val == 'edit') {
                                _mostrarModalCrearTarjeta(tarjetaAEditar: t);
                              } else if (val == 'toggle') {
                                // 🛑 Confirmación
                                bool confirm = await showDialog(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                    title: Text(esActiva ? "¿Inhabilitar Tarjeta?" : "¿Activar Tarjeta?", style: const TextStyle(fontWeight: FontWeight.bold)),
                                    content: Text(esActiva 
                                        ? "¿Deseas inhabilitar \"$tituloTarj\"? No se otorgarán puntos a clientes mientras esté inactiva."
                                        : "¿Deseas activar la tarjeta \"$tituloTarj\"?"),
                                    actions: [
                                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("CANCELAR")),
                                      ElevatedButton(
                                        style: ElevatedButton.styleFrom(backgroundColor: esActiva ? Colors.orange : Colors.green),
                                        onPressed: () => Navigator.pop(ctx, true),
                                        child: Text(esActiva ? "INHABILITAR" : "ACTIVAR", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                      ),
                                    ],
                                  ),
                                ) ?? false;

                                if (!confirm) return;

                                int nuevoEstado = esActiva ? 0 : 1;
                                // 1. SQLite Local
                                await db.update('tarjetas_fidelidad', {'activa': nuevoEstado}, where: 'id = ?', whereArgs: [t['id']]);

                                // 2. Nube / Cola Offline
                                if (user != null) {
                                  if (await ServicioNube.tieneInternet()) {
                                    await FirebaseFirestore.instance
                                        .collection('usuarios')
                                        .doc(user.uid)
                                        .collection('mis_tarjetas_creadas')
                                        .doc(tarjetaIdStr)
                                        .set({'activa': nuevoEstado}, SetOptions(merge: true));
                                  } else {
                                    await db.insert('operaciones_pendientes', {
                                      'tabla': 'mis_tarjetas_creadas',
                                      'operacion': 'set',
                                      'doc_id': tarjetaIdStr,
                                      'datos_json': jsonEncode({'activa': nuevoEstado}),
                                      'fecha_creacion': DateTime.now().toIso8601String(),
                                    }, conflictAlgorithm: ConflictAlgorithm.replace);
                                  }
                                  await ServicioNube.respaldarDatosPrivadosRTDB();
                                }
                                _cargarDatosBD();
                              } else if (val == 'delete') {
                                // 🛑 Confirmación
                                bool confirm = await showDialog(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                    title: const Text("¿Eliminar Tarjeta?", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.redAccent)),
                                    content: Text("¿Estás seguro de que deseas eliminar la tarjeta \"$tituloTarj\"? Esta acción la borrará para ti y tus clientes."),
                                    actions: [
                                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("CANCELAR")),
                                      ElevatedButton(
                                        style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                                        onPressed: () => Navigator.pop(ctx, true),
                                        child: const Text("ELIMINAR", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                                      ),
                                    ],
                                  ),
                                ) ?? false;

                                if (!confirm) return;

                                // 1. SQLite Local
                                await db.delete('tarjetas_fidelidad', where: 'id = ?', whereArgs: [t['id']]);

                                // 2. Nube / Cola Offline
                                if (user != null) {
                                  if (await ServicioNube.tieneInternet()) {
                                    await FirebaseFirestore.instance
                                        .collection('usuarios')
                                        .doc(user.uid)
                                        .collection('mis_tarjetas_creadas')
                                        .doc(tarjetaIdStr)
                                        .delete();
                                  } else {
                                    await db.insert('operaciones_pendientes', {
                                      'tabla': 'mis_tarjetas_creadas',
                                      'operacion': 'delete',
                                      'doc_id': tarjetaIdStr,
                                      'datos_json': null,
                                      'fecha_creacion': DateTime.now().toIso8601String(),
                                    }, conflictAlgorithm: ConflictAlgorithm.replace);
                                  }
                                  await ServicioNube.respaldarDatosPrivadosRTDB();
                                }
                                _cargarDatosBD();
                              }
                            },
                            itemBuilder: (ctx) => [
                              const PopupMenuItem(value: 'edit', child: Row(children: [Icon(Icons.edit, size: 16, color: Colors.orange), SizedBox(width: 8), Text("Editar")])),
                              PopupMenuItem(value: 'toggle', child: Row(children: [Icon(esActiva ? Icons.visibility_off : Icons.visibility, size: 16, color: Colors.blue), SizedBox(width: 8), Text(esActiva ? "Inactivar" : "Activar")])),
                              const PopupMenuItem(value: 'delete', child: Row(children: [Icon(Icons.delete_outline, size: 16, color: Colors.red), SizedBox(width: 8), Text("Eliminar", style: TextStyle(color: Colors.red))])),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),

            // BANNER PUBLICIDAD NO PREMIUM
            if (!_esPremium) ...[
              const SizedBox(height: 25),
              Container(
                padding: const EdgeInsets.all(15),
                decoration: BoxDecoration(color: Colors.orange.withOpacity(0.1), borderRadius: BorderRadius.circular(18), border: Border.all(color: Colors.orange.withOpacity(0.3))),
                child: Row(
                  children: [
                    const Icon(Icons.stars, color: Colors.orange, size: 28),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("Desbloquea Premios Fidelidad", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                          Text("Crea tarjetas de sellos y fideliza a tus clientes.", style: TextStyle(color: Colors.grey, fontSize: 11)),
                        ],
                      ),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.white, minimumSize: const Size(0, 36)),
                      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PantallaPremium())),
                      child: const Text("PRO", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11)),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}