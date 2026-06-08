import 'dart:async';
import 'package:flutter/material.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:ui';

import 'servicio_nube.dart'; 

class PantallaPremium extends StatefulWidget {
  const PantallaPremium({super.key});
  @override
  State<PantallaPremium> createState() => _PantallaPremiumState();
}

class _PantallaPremiumState extends State<PantallaPremium> {
  final InAppPurchase _iap = InAppPurchase.instance;
  bool _procesando = false;
  bool _cargandoTienda = true; 
  ProductDetails? _productoPro; 
  StreamSubscription<List<PurchaseDetails>>? _subscription;

  @override
  void initState() {
    super.initState();
    
    final Stream<List<PurchaseDetails>> purchaseUpdated = _iap.purchaseStream;
    _subscription = purchaseUpdated.listen((purchaseDetailsList) {
      _listenToPurchaseUpdated(purchaseDetailsList);
    }, onDone: () => _subscription?.cancel(), onError: (error) {
      debugPrint("Error en stream: $error");
    });

    _cargarPrecioReal();
    _verificarLicenciaReal(); 
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _verificarLicenciaReal() async {
    try {
      final bool available = await _iap.isAvailable();
      if (!available) return;
      await _iap.restorePurchases();
    } catch (e) {
      debugPrint("Error verificando licencia: $e");
    }
  }

  Future<void> _cargarPrecioReal() async {
    try {
      final bool available = await _iap.isAvailable();
      if (!available) {
        if (mounted) setState(() => _cargandoTienda = false);
        return;
      }

      const Set<String> kIds = {'boxi_premium_pro'};
      final ProductDetailsResponse response = await _iap.queryProductDetails(kIds);

      if (response.productDetails.isNotEmpty) {
        if (mounted) {
          setState(() {
            _productoPro = response.productDetails[0];
            _cargandoTienda = false;
          });
        }
      } else {
        if (mounted) setState(() => _cargandoTienda = false);
      }
    } catch (e) {
      if (mounted) setState(() => _cargandoTienda = false);
    }
  }

  void _listenToPurchaseUpdated(List<PurchaseDetails> purchaseDetailsList) async {
    if (purchaseDetailsList.isEmpty) return; // ✅ simple y seguro

    for (var purchaseDetails in purchaseDetailsList) {
      if (purchaseDetails.status == PurchaseStatus.purchased ||
          purchaseDetails.status == PurchaseStatus.restored) {
        _activarPremiumEnNube(purchaseDetails);
      }

      if (purchaseDetails.status == PurchaseStatus.error) {
        if (purchaseDetails.error?.code == 'billing_response_result_item_already_owned') {
          _iap.restorePurchases();
        } else {
          if (mounted) setState(() => _procesando = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Error: ${purchaseDetails.error?.message}")),
          );
        }
      }

      if (purchaseDetails.pendingCompletePurchase) {
        await _iap.completePurchase(purchaseDetails);
      }
    }
  }

  Future<void> _activarPremiumEnNube(PurchaseDetails purchase) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() => _procesando = true);

    try {
      final db = FirebaseFirestore.instance;
      String idTransaccion = purchase.purchaseID ?? purchase.verificationData.serverVerificationData;

      // 1. Validar si el recibo ya existe en otro usuario o si está reembolsado
      DocumentSnapshot validacion = await db.collection('compras_realizadas').doc(idTransaccion).get();
      if (validacion.exists) {
        Map<String, dynamic> data = validacion.data() as Map<String, dynamic>;
        
        // 🔥 VALIDACIÓN 1: ¿Está reembolsada definitivamente?
        if (data['estado'] == 'reembolsada') {
          if (!mounted) return; 
          setState(() => _procesando = false);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text("Pago Inválido: Esta compra fue reembolsada y no puede usarse."),
              backgroundColor: Colors.red, 
            )
          );
          return; // Lo rebotamos inmediatamente y NO le damos el Premium
        }

        // 🔥 VALIDACIÓN 2: ¿Es de otro usuario? 
        if (data['owner_uid'] != user.uid) {
          setState(() => _procesando = false);
          _mostrarErrorSeguridad(data['email'] ?? "otro correo");
          return; 
        }
      }

      // 2. Registrar compra globalmente
      await db.collection('compras_realizadas').doc(idTransaccion).set({
        'owner_uid': user.uid,
        'email': user.email,
        'fecha': DateTime.now().toIso8601String(),
        'platform': 'android',
        'estado': 'completada', 
      }, SetOptions(merge: true));

      // 3. Activar Premium en el perfil del usuario
      await db.collection('usuarios').doc(user.uid).set({
        'es_premium': true,
        'fecha_pago': DateTime.now().toIso8601String(),
        'order_id': idTransaccion,
        'motivo_degradacion': FieldValue.delete(), // 🔥 Limpia cualquier rastro de reembolso anterior
      }, SetOptions(merge: true));

      // 4. 🔥 SUBIDA MASIVA DE DATOS (De Local a Nube)
      await ServicioNube.sincronizarBaseDatosHaciaNube();

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('es_premium', true);
      await prefs.setString('order_id', idTransaccion);
      if (mounted) {
        setState(() {
          _procesando = false;
        });
        _mostrarDialogoExito();
      }

    } catch (e) {
      if (mounted) {
        setState(() => _procesando = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error activación: $e")));
      }
    }
  }

  Future<void> _comprarNivelPro() async {
    if (_productoPro == null) return; 

    setState(() => _procesando = true);
    try {
      final PurchaseParam purchaseParam = PurchaseParam(productDetails: _productoPro!);
      await _iap.buyNonConsumable(purchaseParam: purchaseParam);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$e"), backgroundColor: Colors.red));
        setState(() => _procesando = false);
      }
    }
  }

  void _mostrarDialogoExito() {
    showDialog(context: context, barrierDismissible: false, builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1B263B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: Colors.amberAccent)),
        title: const Icon(Icons.verified_user, color: Colors.greenAccent, size: 60),
        content: const Text("¡BIENVENIDO AL PREMIUM!\nTu inventario se ha sincronizado con la nube.", textAlign: TextAlign.center, style: TextStyle(color: Colors.white)),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.amberAccent),
            onPressed: () => Navigator.of(ctx).popUntil((route) => route.isFirst), 
            child: const Text("EMPEZAR", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold))
          )
        ],
    ));
  }

  void _mostrarErrorSeguridad(String emailVinculado) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1B263B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Icon(Icons.lock_person, color: Colors.orangeAccent, size: 50),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("PAGO YA VINCULADO", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            Text("Esta compra ya está asociada a la cuenta:\n\n$emailVinculado", 
              textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 13)),
          ],
        ),
        actions: [ TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("ENTENDIDO")) ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0E21),
      body: Stack(
        children: [
          _buildFondoDecorativo(),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(30),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.07), 
                      borderRadius: BorderRadius.circular(30), 
                      border: Border.all(color: Colors.amberAccent.withOpacity(0.3))
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.workspace_premium_rounded, size: 70, color: Colors.amberAccent),
                        const Text("BOXI NIVEL PRO", style: TextStyle(color: Colors.amberAccent, fontSize: 28, fontWeight: FontWeight.w900)),
                        const SizedBox(height: 20),
                        _tablaComparativa(),
                        const SizedBox(height: 25),
                        const Text("PAGO ÚNICO - ACCESO DE POR VIDA", style: TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold)),
                        if (_cargandoTienda)
                           const Padding(
                             padding: EdgeInsets.symmetric(vertical: 10),
                             child: CircularProgressIndicator(color: Colors.amberAccent, strokeWidth: 2),
                           )
                        else
                          Text(
                            _productoPro?.price ?? "\$8.25 USD", 
                            style: const TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.w900)
                          ),
                        const SizedBox(height: 25),
                        if (_procesando) 
                          const Column(
                            children: [
                              CircularProgressIndicator(color: Colors.amberAccent),
                              SizedBox(height: 10),
                              Text("Sincronizando con la nube...", style: TextStyle(color: Colors.amberAccent, fontSize: 12))
                            ],
                          )
                        else Column(
                          children: [
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: _productoPro != null ? Colors.amberAccent : Colors.grey, 
                                minimumSize: const Size(double.infinity, 60), 
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))
                              ),
                              onPressed: _productoPro != null ? _comprarNivelPro : null,
                              child: const Text("OBTENER NIVEL PRO 👑", style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: Colors.black)),
                            ),
                          ],
                        ),
                        TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cerrar", style: TextStyle(color: Colors.white38)))
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tablaComparativa() {
    return Container(
      decoration: BoxDecoration(color: Colors.black.withOpacity(0.3), borderRadius: BorderRadius.circular(15)),
      child: Column(
        children: [
          _filaHeader(),
          _filaDato("Límite Productos", "Hasta 50", "Ilimitados"),
          _filaDato("Publicidad", "Con Anuncios", "Sin Anuncios"),
          _filaDato("Sincronización Nube", "❌", "✅"),
          _filaDato("Multi-dispositivo", "❌", "✅"),
          _filaDato("Catálogo Web", "❌", "✅"),
          _filaDato("Respaldo Automático", "Manual", "✅"),
          _filaDato("Reportes PDF", "Mensual", "Personalizado"),
          _filaDato("Logo en Facturas", "❌", "✅"),
        ],
      ),
    );
  }

  Widget _filaHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
      decoration: BoxDecoration(color: Colors.white.withOpacity(0.05), borderRadius: const BorderRadius.vertical(top: Radius.circular(15))),
      child: const Row(
        children: [
          Expanded(flex: 3, child: Text("Característica", style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 11))),
          Expanded(flex: 2, child: Text("GRATIS", textAlign: TextAlign.center, style: TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 11))),
          Expanded(flex: 2, child: Text("PRO", textAlign: TextAlign.center, style: TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold, fontSize: 11))),
        ],
      ),
    );
  }

  Widget _filaDato(String feature, String free, String pro) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Colors.white10, width: 0.5))),
      child: Row(
        children: [
          Expanded(flex: 3, child: Text(feature, style: const TextStyle(color: Colors.white, fontSize: 10.5))),
          Expanded(flex: 2, child: Text(free, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white38, fontSize: 10.5))),
          Expanded(flex: 2, child: Text(pro, textAlign: TextAlign.center, style: const TextStyle(color: Colors.amberAccent, fontWeight: FontWeight.bold, fontSize: 10.5))),
        ],
      ),
    );
  }

  Widget _buildFondoDecorativo() => Container(decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0xFF0D1B2A), Color(0xFF1B263B)], begin: Alignment.topLeft, end: Alignment.bottomRight)));
}