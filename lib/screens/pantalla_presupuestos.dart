import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart'; 
import 'package:local_auth/local_auth.dart'; 
import '../database/db_helper.dart';
import 'servicio_nube.dart';
import 'servicio_anuncios.dart';
import 'pantalla_premium.dart';
import 'pantalla_bienvenida.dart'; 
import 'servicio_pdf.dart';

class PantallaPresupuestos extends StatefulWidget {
  const PantallaPresupuestos({super.key});
  @override
  State<PantallaPresupuestos> createState() => _PantallaPresupuestosState();
}

class _PantallaPresupuestosState extends State<PantallaPresupuestos> {
  double inversionEnBodega = 0;
  double utilidadProyectada = 0;
  double cajaTotalMes = 0;
  double gananciaNetaMes = 0;
  double capitalGlobalReinversion = 0; 
  Timer? _debounce;
  
  List<Map<String, dynamic>> _productosStock = [];
  List<Map<String, dynamic>> _desgloseMesActual = [];
  List<Map<String, dynamic>> _historialReportes = [];
  List<Map<String, dynamic>> _capitalPorVentaProds = [];
  List<Map<String, dynamic>> _capitalManualAjustes = [];

  final List<StreamSubscription> _suscripciones = [];
  bool _incluirLogoEnReporte = true;
  bool _esPremiumUsuario = false;

  final LocalAuthentication _localAuth = LocalAuthentication(); 

  @override
  void initState() {
    super.initState();
    _inicializarPantalla();
  }

  Future<void> _inicializarPantalla() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _esPremiumUsuario = prefs.getBool('es_premium') ?? false;
    });
    await _ejecutarMotorFinanciero();
    _activarSincronizacionEnVivo();
    _verificarReporteMensualAutomatico();
  }

  @override
  void dispose() {
    _debounce?.cancel(); 
    for (var s in _suscripciones) { s.cancel(); }
    super.dispose();
  }

  void _activarSincronizacionEnVivo() async {
    if (!_esPremiumUsuario) return;

    void recalcularConDebounce() {
      _debounce?.cancel();
      _debounce = Timer(const Duration(seconds: 3), () {
        _ejecutarMotorFinanciero();
      });
    }

    _suscripciones.add(ServicioNube.escucharProductosEnTiempoReal()!.listen((snap) => recalcularConDebounce()));
    _suscripciones.add(ServicioNube.escucharPedidosEnTiempoReal()!.listen((snap) => recalcularConDebounce()));
    _suscripciones.add(ServicioNube.escucharAjustesCapitalEnTiempoReal()!.listen((snap) => recalcularConDebounce()));
    _suscripciones.add(ServicioNube.escucharReportesEnTiempoReal()!.listen((snapshot) async {
      final db = await DBHelper.instance.database;

      for (var change in snapshot.docChanges) {
        final data = change.doc.data() as Map<String, dynamic>;
        final int id = int.tryParse(change.doc.id) ?? (data['id'] as int? ?? -1);

        if (change.type == DocumentChangeType.removed) {
          await db.delete('reportes_guardados', where: 'id = ?', whereArgs: [id]);
        } else {
          Map<String, dynamic> localData = Map.from(data);
          localData.updateAll((key, value) => value is Timestamp ? value.toDate().toIso8601String() : value);
          const permitidas = ['id', 'titulo', 'fecha', 'caja', 'utilidad', 'reinversion', 'detalle_json', 'ultima_modificacion'];
          localData.removeWhere((key, _) => !permitidas.contains(key));
          localData['id'] = id;
          await db.insert('reportes_guardados', localData, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      if (mounted) _ejecutarMotorFinanciero();
    }));
  }

  Future<void> _verificarReporteMensualAutomatico() async {
    final now = DateTime.now();
    final mesPasado = DateTime(now.year, now.month - 1);
    final String idMesPasado = "${mesPasado.year}-${mesPasado.month.toString().padLeft(2, '0')}";
    final String nombreReporteAuto = "REPORTE MES-${mesPasado.month.toString().padLeft(2, '0')}-${mesPasado.year}";

    final db = await DBHelper.instance.database;
    final existe = await db.query('reportes_guardados', columns: ['id'], where: 'titulo = ?', whereArgs: [nombreReporteAuto], limit: 1);

    if (existe.isEmpty) {
      // 🔥 EXTREMA SEGURIDAD DE MEMORIA: Solo traer ID para validar, sin saturar la RAM
      final ventasPasadas = await db.query('pedidos', columns: ['id'], where: "estado = 'Completado' AND substr(fecha_hora, 1, 7) = ?", whereArgs: [idMesPasado], limit: 1);
      if (ventasPasadas.isNotEmpty) {
        _procederReporteMes(nombreReporteAuto, manual: false, mesReferencia: idMesPasado);
      }
    }
  }

  Future<void> _ejecutarMotorFinanciero() async {
    try {
      final Database db = await DBHelper.instance.database;
      final now = DateTime.now();
      final String mesActualStr = "${now.year}-${now.month.toString().padLeft(2, '0')}";
      
      // 1. INVENTARIO
      final prods = await db.query('productos', columns: ['id', 'nombre', 'stock', 'variantes', 'precio_compra', 'precio_venta']);
      List<Map<String, dynamic>> prodsProcesados = [];
      double invBodega = 0, utilProy = 0;
      for (var p in prods) {
        int stockReal = (p['stock'] ?? 0) as int;
        String varStr = p['variantes']?.toString() ?? "";
        if (varStr.length > 5) {
          try {
            List<dynamic> grps = jsonDecode(varStr);
            int sVar = 0;
            for (var g in grps) { for (var o in g['opciones']) { sVar += (o['stock'] ?? 0) as int; } }
            stockReal = sVar;
          } catch(e) {}
        }
        double pC = (p['precio_compra'] as num? ?? 0).toDouble();
        double pV = (p['precio_venta'] as num? ?? 0).toDouble();
        invBodega += pC * stockReal;
        utilProy += (pV - pC) * stockReal;
        var pClon = Map<String, dynamic>.from(p);
        pClon['stock_procesado'] = stockReal;
        prodsProcesados.add(pClon);
      }

      // 2. CAPITAL GLOBAL
      final capitalVentasRaw = await db.rawQuery('''
        SELECT d.nombre_snapshot, SUM(d.cantidad) as cantidad_total, SUM(d.cantidad * (SELECT precio_compra FROM productos WHERE id = d.producto_id)) as capital_recuperado
        FROM detalle_pedidos d JOIN pedidos p ON d.pedido_id = p.id
        WHERE p.estado = 'Completado' GROUP BY d.producto_id, d.nombre_snapshot HAVING capital_recuperado > 0
      ''');

      // 🔥 LÍMITE DE MEMORIA: Solo los últimos 150 ajustes manuales
      final ajustesManuales = await db.query('ajustes_capital', columns: ['id', 'monto', 'descripcion', 'fecha'], orderBy: 'id DESC', limit: 150);

      final totalRecuperadoVentas = await db.rawQuery("SELECT SUM(cantidad * (SELECT precio_compra FROM productos WHERE id = producto_id)) as total FROM detalle_pedidos WHERE pedido_id IN (SELECT id FROM pedidos WHERE estado = 'Completado')");
      final totalGastadoQ = await db.rawQuery("SELECT SUM(monto) as total FROM ajustes_capital");
      
      double capRecup = (totalRecuperadoVentas.first['total'] as num? ?? 0).toDouble();
      double capAjust = (totalGastadoQ.first['total'] as num? ?? 0).toDouble();
      double capitalDispo = capRecup - capAjust;

      // 3. MÉTRICAS DEL MES
      final metricasMes = await db.rawQuery("SELECT SUM(total_venta) as cajaMes, SUM(ganancia_total + COALESCE(valor_domicilio, 0)) as utilMes FROM pedidos WHERE estado = 'Completado' AND substr(fecha_hora, 1, 7) = ?", [mesActualStr]);
      double cajaMes = (metricasMes.first['cajaMes'] as num? ?? 0).toDouble();
      double utilMes = (metricasMes.first['utilMes'] as num? ?? 0).toDouble();

      // 4. DESGLOSE DETALLADO POR CLIENTE
      final clientesRaw = await db.rawQuery('''
        SELECT c.id as cliente_id, COALESCE(c.nombre_completo, 'Cliente Temporal') as nombre_completo, c.nombre_negocio,
               SUM(p.total_venta) as recaudado, SUM(p.ganancia_total + COALESCE(p.valor_domicilio, 0)) as ganancia_neta, SUM(COALESCE(p.valor_domicilio, 0)) as total_domicilios
        FROM pedidos p LEFT JOIN clientes c ON p.cliente_id = c.id
        WHERE p.estado = 'Completado' AND substr(p.fecha_hora, 1, 7) = ? GROUP BY p.cliente_id
      ''', [mesActualStr]);

      List<Map<String, dynamic>> desgloseMesDefinitivo = [];
      for (var c in clientesRaw) {
        final itemsAgrupados = await db.rawQuery('''
          SELECT d.nombre_snapshot, SUM(d.cantidad) as total_cant, d.descuento, d.precio_unitario, (SELECT precio_compra FROM productos WHERE id = d.producto_id) as p_compra
          FROM detalle_pedidos d JOIN pedidos p ON d.pedido_id = p.id
          WHERE p.cliente_id = ? AND p.estado = 'Completado' AND substr(p.fecha_hora, 1, 7) = ?
          GROUP BY d.nombre_snapshot, d.descuento, d.precio_unitario, d.producto_id
        ''', [c['cliente_id'], mesActualStr]);

        List<String> listaRecogido = [];
        List<String> listaGanancia = [];
        
        for (var i in itemsAgrupados) {
          double costoU = (i['p_compra'] as num? ?? 0).toDouble();
          double pBaseV = (i['precio_unitario'] as num? ?? 0).toDouble();
          double dPct = (i['descuento'] as num? ?? 0).toDouble();
          int cant = (i['total_cant'] as num? ?? 0).toInt();

          double pVentaF = pBaseV - (pBaseV * (dPct / 100));
          double totalRec = pVentaF * cant;
          double gananciaL = (pVentaF - costoU) * cant;
          
          String descStr = dPct > 0 ? " [-$dPct%]" : "";
          listaRecogido.add("• ${i['nombre_snapshot']}$descStr (x$cant) - \$${totalRec.toStringAsFixed(0)}");
          String ganTxt = gananciaL >= 0 ? "(G: +\$${gananciaL.toStringAsFixed(0)})" : "(PÉRDIDA: \$${gananciaL.toStringAsFixed(0)})";
          listaGanancia.add("• ${i['nombre_snapshot']}$descStr (x$cant) -> $ganTxt");
        }

        double doms = (c['total_domicilios'] as num? ?? 0).toDouble();
        if (doms > 0) {
          listaRecogido.add("🛵 DOMICILIOS/ENVÍOS - \$${doms.toStringAsFixed(0)}");
          listaGanancia.add("🛵 DOMICILIOS/ENVÍOS -> (G: +\$${doms.toStringAsFixed(0)})");
        }

        desgloseMesDefinitivo.add({
          'nombre_completo': c['nombre_completo'], 'nombre_negocio': c['nombre_negocio'],
          'recaudado': (c['recaudado'] as num? ?? 0).toDouble(), 'ganancia': (c['ganancia_neta'] as num? ?? 0).toDouble(),
          'articulos_recogido': listaRecogido, 'articulos_ganancia': listaGanancia,
        });
      }

      // 🔥 LÍMITE DE MEMORIA CRÍTICO: Máximo 150 reportes históricos en RAM sin la columna gigante de JSON.
      final reportes = await db.query(
        'reportes_guardados', 
        columns: ['id', 'titulo', 'fecha', 'caja', 'utilidad', 'reinversion', 'ultima_modificacion'],
        orderBy: "id DESC",
        limit: 150
      );

      if (mounted) {
        setState(() {
          _productosStock = prodsProcesados;
          _desgloseMesActual = desgloseMesDefinitivo; 
          _historialReportes = reportes;
          _capitalPorVentaProds = List<Map<String, dynamic>>.from(capitalVentasRaw);
          _capitalManualAjustes = List<Map<String, dynamic>>.from(ajustesManuales);
          inversionEnBodega = invBodega; utilidadProyectada = utilProy;
          cajaTotalMes = cajaMes; gananciaNetaMes = utilMes; capitalGlobalReinversion = capitalDispo;
        });
      }
    } catch (e) {
      debugPrint("Error motor financiero: $e");
    }
  }

  Future<void> _procederReporteMes(String titulo, {bool manual = true, String? mesReferencia}) async {
    final db = await DBHelper.instance.database;
    final now = DateTime.now();
    final String mesTarget = mesReferencia ?? "${now.year}-${now.month.toString().padLeft(2, '0')}";

    final List<Map<String, dynamic>> peds = await db.rawQuery('''
      SELECT p.fecha_hora, p.total_venta, (p.ganancia_total + COALESCE(p.valor_domicilio, 0)) as ganancia_real, c.nombre_completo, c.nombre_negocio
      FROM pedidos p LEFT JOIN clientes c ON p.cliente_id = c.id
      WHERE p.estado = 'Completado' AND substr(p.fecha_hora, 1, 7) = ?
    ''', [mesTarget]);

    if (peds.isEmpty) {
      if (manual && mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Sin ventas completadas para este mes."), backgroundColor: Colors.orange));
      return;
    }

    double tC = 0, tU = 0;
    for (var p in peds) { tC += (p['total_venta'] as num? ?? 0).toDouble(); tU += (p['ganancia_real'] as num? ?? 0).toDouble(); }

    final reporteMap = {
      'titulo': titulo, 'fecha': now.toIso8601String(),
      'caja': tC, 'utilidad': tU, 'reinversion': (tC - tU),
      'detalle_json': jsonEncode(peds), 'ultima_modificacion': now.toIso8601String(),
    };

    int id = await db.insert('reportes_guardados', reporteMap);
    if (_esPremiumUsuario) ServicioNube.guardarReporteNube({...reporteMap, 'id': id});

    if (manual) _generarPdfProfesional(reporteMap);
    _ejecutarMotorFinanciero();
  }

  Future<void> _generarPdfProfesional(Map<String, dynamic> r) async {
    final prefs = await SharedPreferences.getInstance();
    final String nombreNeg = (prefs.getString('nombre_negocio') ?? "Mi Negocio").toUpperCase();
    final String? logoPath = _esPremiumUsuario ? prefs.getString('logo_path') : null;
    
    String jsonStr = "";
    if (r.containsKey('detalle_json') && r['detalle_json'] != null) {
      jsonStr = r['detalle_json'];
    } else {
      final db = await DBHelper.instance.database;
      final queryRes = await db.query('reportes_guardados', columns: ['detalle_json'], where: 'id = ?', whereArgs: [r['id']]);
      if (queryRes.isNotEmpty && queryRes.first['detalle_json'] != null) jsonStr = queryRes.first['detalle_json'] as String;
    }

    final List<dynamic> ventas = jsonStr.isNotEmpty ? jsonDecode(jsonStr) : [];

    await ServicioPdf.compartirReporte(
      titulo: r['titulo'].toString(), totalCaja: (r['caja'] as num).toDouble(),
      totalUtilidad: (r['utilidad'] as num).toDouble(), ventas: ventas,
      nombreNegocio: nombreNeg, logoPath: logoPath,
      mostrarLogo: _esPremiumUsuario && _incluirLogoEnReporte,
    );
  }

  Widget _scrollableListContainer({required List<Widget> children}) {
    if (children.isEmpty) return const SizedBox.shrink();
    return Container(
      constraints: const BoxConstraints(maxHeight: 180), 
      child: SingleChildScrollView(
        primary: false, physics: const ClampingScrollPhysics(),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: children),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isOscuro ? const Color(0xFF0A0A0F) : const Color(0xFFF5F7FA),
      appBar: AppBar(
        title: const Text('CENTRO FINANCIERO', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        backgroundColor: isOscuro ? const Color(0xFF0D1B2A) : const Color(0xFF0D47A1), 
        foregroundColor: Colors.white,
        actions: [
          IconButton(icon: const Icon(Icons.calendar_month), onPressed: _generarReporteRango),
          IconButton(icon: const Icon(Icons.picture_as_pdf, color: Colors.orangeAccent), onPressed: _generarReporteMesBoton),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(15),
        child: Column(
          children: [
            _cardInventario('Inversión en Bodega (Costo)', inversionEnBodega, const Color(0xFF1565C0), _productosStock, 'compra', isOscuro),
            _cardInventario('Ganancia Proyectada (Inventario)', utilidadProyectada, const Color(0xFFE65100), _productosStock, 'utilidad', isOscuro),
            const SizedBox(height: 20),
            _cardGlobal('Capital Reinversión (Fondo para Stock)', capitalGlobalReinversion, const Color(0xFF00695C), Icons.account_balance_wallet, isOscuro),
            const SizedBox(height: 20),
            _cardVentasMes('RECOGIDO TOTAL DEL MES', cajaTotalMes, const Color(0xFF2E7D32), _desgloseMesActual, 'recaudado', esGanancia: false, isOscuro: isOscuro),
            _cardVentasMes('GANANCIA REAL DEL MES', gananciaNetaMes, const Color(0xFF388E3C), _desgloseMesActual, 'ganancia', esGanancia: true, isOscuro: isOscuro),
            const SizedBox(height: 30),
            _buildSeccionHistorial("REPORTES MANUALES", "REPORTE-", Colors.orange, isOscuro),
            _buildSeccionHistorial("REPORTES ENTRE FECHAS", "REPORTE ", Colors.blue, isOscuro, excludePrefijo: "REPORTE MES-"), 
            _buildSeccionHistorial("REPORTES MENSUALES (AUTO)", "REPORTE MES-", Colors.green, isOscuro),
          ],
        ),
      ),
    );
  }

  Future<bool> _verificarIdentidadUrgente() async {
    final prefs = await SharedPreferences.getInstance();
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;

    bool biometriaActiva = prefs.getBool('admin_biometria_activa') ?? false;
    if (biometriaActiva) {
      try {
        bool autenticado = await _localAuth.authenticate(
          localizedReason: 'Confirmar acción de seguridad financiera',
          options: const AuthenticationOptions(biometricOnly: false, stickyAuth: true, useErrorDialogs: true),
        );
        if (autenticado) return true;
      } catch (e) { debugPrint("Error biometría: $e"); }
    }

    String? passwordAdmin = prefs.getString('admin_password');
    if (passwordAdmin != null) return await _pedirPasswordManual(user, esAdminPass: true);
    return await _pedirPasswordManual(user, esAdminPass: false);
  }

  Future<bool> _pedirPasswordManual(User user, {required bool esAdminPass}) async {
    final passCtrl = TextEditingController();
    bool validando = false;
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;
    bool esGoogle = user.providerData.any((p) => p.providerId == 'google.com');

    bool? exito = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setSt) {
          return AlertDialog(
            backgroundColor: Theme.of(context).cardColor,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: esAdminPass ? Colors.cyanAccent : Colors.orangeAccent, width: 1)),
            title: Row(
              children: [
                Icon(Icons.security, color: esAdminPass ? Colors.cyanAccent : Colors.orangeAccent), const SizedBox(width: 8),
                Expanded(child: Text(esAdminPass ? "Seguridad Administrador" : "Seguridad de Cuenta", style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold))),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(esAdminPass ? "Ingresa tu contraseña de administración local para autorizar la acción." : (esGoogle ? "Iniciaste sesión con Google. Por seguridad, ingresa tu correo de Boxi para confirmar: (${user.email})" : "No tienes clave admin. Confirma ingresando la contraseña de tu cuenta de Boxi (${user.email})."),
                  style: TextStyle(fontSize: 12, color: isOscuro ? Colors.white60 : Colors.black54),
                ),
                const SizedBox(height: 15),
                if (esGoogle && !esAdminPass) TextField(controller: passCtrl, keyboardType: TextInputType.emailAddress, style: TextStyle(color: isOscuro ? Colors.white : Colors.black), decoration: const InputDecoration(labelText: "Confirmar Correo", border: OutlineInputBorder(), prefixIcon: Icon(Icons.email)))
                else TextField(controller: passCtrl, obscureText: true, style: TextStyle(color: isOscuro ? Colors.white : Colors.black), decoration: const InputDecoration(labelText: "Contraseña", border: OutlineInputBorder(), prefixIcon: Icon(Icons.lock))),
                if (validando) const Padding(padding: EdgeInsets.only(top: 15), child: CircularProgressIndicator())
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("CANCELAR", style: TextStyle(color: Colors.grey))),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: esAdminPass ? Colors.cyanAccent.shade700 : Colors.orangeAccent, foregroundColor: esAdminPass ? Colors.white : Colors.black),
                onPressed: validando ? null : () async {
                  String input = passCtrl.text.trim();
                  if (input.isEmpty) return;
                  setSt(() => validando = true);
                  try {
                    if (esAdminPass) {
                      if (await ServicioContrasenaAdmin.validarPassword(input, user.uid)) { Navigator.pop(ctx, true); } else { throw "Contraseña incorrecta"; }
                    } else {
                      if (esGoogle) {
                        if (input.toLowerCase() == user.email!.toLowerCase()) { Navigator.pop(ctx, true); } else { throw "El correo no coincide"; }
                      } else {
                        AuthCredential credential = EmailAuthProvider.credential(email: user.email!, password: input);
                        await user.reauthenticateWithCredential(credential);
                        Navigator.pop(ctx, true);
                      }
                    }
                  } catch (e) {
                    setSt(() => validando = false);
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("❌ Error: $e"), backgroundColor: Colors.red));
                  }
                },
                child: const Text("CONFIRMAR", style: TextStyle(fontWeight: FontWeight.bold)),
              )
            ],
          );
        }
      ),
    );
    return exito ?? false;
  }

  void _reiniciarCapitalConfirmacion() {
    showDialog(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: Theme.of(context).cardColor, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Row(children: [Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 28), SizedBox(width: 10), Text("¿Reiniciar Capital?", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.redAccent))]),
      content: const Text("Se borrarán permanentemente todos los registros de compras de stock y ajustes manuales. ¿Estás seguro de continuar?"),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR")),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
          onPressed: () async {
            Navigator.pop(ctx);
            if (await _verificarIdentidadUrgente()) {
              final db = await DBHelper.instance.database;
              await db.delete('ajustes_capital');
              if (_esPremiumUsuario) {
                final uid = (await SharedPreferences.getInstance()).getString('user_uid');
                if (uid != null) {
                  final snapshot = await FirebaseFirestore.instance.collection('usuarios').doc(uid).collection('ajustes_capital').get();
                  WriteBatch batch = FirebaseFirestore.instance.batch();
                  for (var doc in snapshot.docs) { batch.delete(doc.reference); }
                  await batch.commit();
                  await FirebaseFirestore.instance.collection('usuarios').doc(uid).update({'ultima_mod_ajustes': FieldValue.serverTimestamp()});
                }
              }
              _ejecutarMotorFinanciero();
            }
          },
          child: const Text("REINICIAR", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        )
      ],
    ));
  }

  void _ajustarCapitalManualDialogo() {
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;
    final TextEditingController montoCtrl = TextEditingController();
    final TextEditingController descCtrl = TextEditingController();
    bool esGasto = true; 

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setSt) {
          return AlertDialog(
            backgroundColor: Theme.of(context).cardColor, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Text("Ajustar Capital Manual", style: TextStyle(fontWeight: FontWeight.bold, color: isOscuro ? Colors.white : Colors.black, fontSize: 16)),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 10),
                  TextField(controller: montoCtrl, keyboardType: TextInputType.number, style: TextStyle(color: isOscuro ? Colors.white : Colors.black), decoration: InputDecoration(labelText: "Monto (\$)", labelStyle: TextStyle(color: isOscuro ? Colors.white60 : Colors.black54), border: const OutlineInputBorder(), prefixIcon: const Icon(Icons.attach_money, color: Colors.green))),
                  const SizedBox(height: 15),
                  TextField(controller: descCtrl, style: TextStyle(color: isOscuro ? Colors.white : Colors.black), decoration: InputDecoration(labelText: "Descripción", labelStyle: TextStyle(color: isOscuro ? Colors.white60 : Colors.black54), border: const OutlineInputBorder(), prefixIcon: const Icon(Icons.description, color: Colors.blueGrey))),
                  const SizedBox(height: 15),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(color: isOscuro ? Colors.white.withOpacity(0.05) : Colors.grey.shade100, borderRadius: BorderRadius.circular(10), border: Border.all(color: isOscuro ? Colors.white10 : Colors.grey.shade300)),
                    child: SwitchListTile(contentPadding: EdgeInsets.zero, title: Text(esGasto ? "EGRESO / COMPRA DE STOCK (-)" : "INGRESO / APORTE (+)", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: esGasto ? Colors.redAccent : Colors.greenAccent)), value: esGasto, activeColor: Colors.redAccent, inactiveTrackColor: Colors.greenAccent.withOpacity(0.4), inactiveThumbColor: Colors.greenAccent, onChanged: (v) => setSt(() => esGasto = v)),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR")),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: esGasto ? Colors.redAccent : Colors.greenAccent, foregroundColor: esGasto ? Colors.white : Colors.black),
                onPressed: () async {
                  double val = double.tryParse(montoCtrl.text) ?? 0;
                  if (val <= 0) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("⚠️ Ingresa un monto válido"), backgroundColor: Colors.orange)); return; }
                  Navigator.pop(ctx);
                  if (await _verificarIdentidadUrgente()) {
                    double montoFinal = esGasto ? val : -val; 
                    final db = await DBHelper.instance.database;
                    Map<String, dynamic> ajusteData = {
                      'monto': montoFinal, 'fecha': DateTime.now().toIso8601String(),
                      'descripcion': descCtrl.text.trim().isEmpty ? (esGasto ? "Ajuste manual (Egreso)" : "Ajuste manual (Ingreso)") : descCtrl.text.trim(),
                    };
                    int idAjuste = await db.insert('ajustes_capital', ajusteData);
                    if (_esPremiumUsuario) {
                      final uid = (await SharedPreferences.getInstance()).getString('user_uid');
                      if (uid != null) {
                        await FirebaseFirestore.instance.collection('usuarios').doc(uid).collection('ajustes_capital').doc(idAjuste.toString()).set({...ajusteData, 'id': idAjuste, 'ultima_modificacion': FieldValue.serverTimestamp()});
                        await FirebaseFirestore.instance.collection('usuarios').doc(uid).update({'ultima_mod_ajustes': FieldValue.serverTimestamp()});
                      }
                    }
                    _ejecutarMotorFinanciero();
                  }
                },
                child: const Text("GUARDAR", style: TextStyle(fontWeight: FontWeight.bold)),
              )
            ],
          );
        }
      ),
    );
  }

  void _eliminarReporteConfirmacion(Map<String, dynamic> r) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).cardColor, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(children: [Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 28), SizedBox(width: 10), Text("¿Eliminar Reporte?", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.redAccent))]),
        content: Text("Se eliminará permanentemente el reporte \"${r['titulo']}\". ¿Deseas continuar?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () async {
              Navigator.pop(ctx);
              if (await _verificarIdentidadUrgente()) {
                final db = await DBHelper.instance.database;
                int id = r['id'] as int;
                await db.delete('reportes_guardados', where: 'id = ?', whereArgs: [id]);
                if (_esPremiumUsuario) {
                  final uid = (await SharedPreferences.getInstance()).getString('user_uid');
                  if (uid != null) await FirebaseFirestore.instance.collection('usuarios').doc(uid).collection('reportes_guardados').doc(id.toString()).delete();
                }
                _ejecutarMotorFinanciero();
              }
            },
            child: const Text("ELIMINAR", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          )
        ],
      )
    );
  }

  // 🔥 NUEVA FUNCIÓN: Eliminar TODOS los reportes de una sección (Con seguridad y lote de Firebase)
  void _eliminarTodosReportesConfirmacion(String tituloSeccion, List<Map<String, dynamic>> reportesABorrar) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).cardColor, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(children: [Icon(Icons.delete_sweep, color: Colors.redAccent, size: 28), SizedBox(width: 10), Text("¿Borrar Todos?", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.redAccent))]),
        content: Text("Se eliminarán permanentemente los ${reportesABorrar.length} reportes de la sección \"$tituloSeccion\". Esta acción NO se puede deshacer.\n\n¿Estás completamente seguro?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () async {
              Navigator.pop(ctx);
              if (await _verificarIdentidadUrgente()) {
                final db = await DBHelper.instance.database;
                WriteBatch? batch;
                String? uid;
                if (_esPremiumUsuario) {
                  uid = (await SharedPreferences.getInstance()).getString('user_uid');
                  if (uid != null) batch = FirebaseFirestore.instance.batch();
                }

                for (var r in reportesABorrar) {
                  int id = r['id'] as int;
                  await db.delete('reportes_guardados', where: 'id = ?', whereArgs: [id]);
                  if (batch != null && uid != null) {
                    final docRef = FirebaseFirestore.instance.collection('usuarios').doc(uid).collection('reportes_guardados').doc(id.toString());
                    batch.delete(docRef);
                  }
                }
                if (batch != null) await batch.commit();
                
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Reportes eliminados correctamente."), backgroundColor: Colors.green));
                _ejecutarMotorFinanciero();
              }
            },
            child: const Text("ELIMINAR TODOS", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          )
        ],
      )
    );
  }

  void _eliminarCapitalRecuperadoConfirmacion(String nombreSnapshot) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).cardColor, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(children: [Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 28), SizedBox(width: 10), Text("¿Eliminar Historial?", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.redAccent))]),
        content: Text("Se borrará el costo recuperado de \"$nombreSnapshot\" de tus ventas completadas. Esto modificará tus métricas de capital global. ¿Deseas continuar?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () async {
              Navigator.pop(ctx);
              if (await _verificarIdentidadUrgente()) {
                final db = await DBHelper.instance.database;
                if (_esPremiumUsuario) {
                  final uid = (await SharedPreferences.getInstance()).getString('user_uid');
                  if (uid != null) {
                    final pedsCompletados = await db.query('pedidos', columns: ['id'], where: 'estado = "Completado"');
                    List<int> idsCompletados = pedsCompletados.map((p) => p['id'] as int).toList();
                    if (idsCompletados.isNotEmpty) {
                      String placeholders = List.filled(idsCompletados.length, '?').join(', ');
                      final detNube = await db.query('detalle_pedidos', where: 'nombre_snapshot = ? AND pedido_id IN ($placeholders)', whereArgs: [nombreSnapshot, ...idsCompletados]);
                      WriteBatch batch = FirebaseFirestore.instance.batch();
                      for (var d in detNube) { batch.delete(FirebaseFirestore.instance.collection('usuarios').doc(uid).collection('detalle_pedidos').doc(d['id'].toString())); }
                      await batch.commit();
                    }
                  }
                }
                await db.rawDelete("DELETE FROM detalle_pedidos WHERE nombre_snapshot = ? AND pedido_id IN (SELECT id FROM pedidos WHERE estado = 'Completado')", [nombreSnapshot]);
                _ejecutarMotorFinanciero();
              }
            },
            child: const Text("ELIMINAR", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          )
        ],
      )
    );
  }

  void _eliminarAjusteManualConfirmacion(Map<String, dynamic> ajuste) {
    int id = ajuste['id'] as int;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Theme.of(context).cardColor, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(children: [Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 28), SizedBox(width: 10), Text("¿Eliminar Ajuste?", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: Colors.redAccent))]),
        content: Text("Se eliminará permanentemente el ajuste \"${ajuste['descripcion']}\". ¿Deseas continuar?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () async {
              Navigator.pop(ctx);
              if (await _verificarIdentidadUrgente()) {
                final db = await DBHelper.instance.database;
                await db.delete('ajustes_capital', where: 'id = ?', whereArgs: [id]);
                if (_esPremiumUsuario) {
                  final uid = (await SharedPreferences.getInstance()).getString('user_uid');
                  if (uid != null) {
                    await FirebaseFirestore.instance.collection('usuarios').doc(uid).collection('ajustes_capital').doc(id.toString()).delete();
                    await FirebaseFirestore.instance.collection('usuarios').doc(uid).update({'ultima_mod_ajustes': FieldValue.serverTimestamp()});
                  }
                }
                _ejecutarMotorFinanciero();
              }
            },
            child: const Text("ELIMINAR", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          )
        ],
      )
    );
  }

  Widget _cardGlobal(String t, double m, Color c, IconData icon, bool isOscuro) => Card(
    color: isOscuro ? Theme.of(context).cardColor : c, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: isOscuro ? c.withOpacity(0.5) : Colors.transparent)),
    child: ExpansionTile(
      leading: Icon(icon, color: isOscuro ? c : Colors.white, size: 26), iconColor: isOscuro ? c : Colors.white, collapsedIconColor: isOscuro ? c : Colors.white,
      title: Text(t, style: TextStyle(color: isOscuro ? Colors.white70 : Colors.white, fontSize: 13)), 
      subtitle: Text('\$${m.toStringAsFixed(0)}', style: TextStyle(color: isOscuro ? c : Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10), decoration: BoxDecoration(color: isOscuro ? Colors.black26 : Colors.white.withOpacity(0.1)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _subtituloDesglose("CAPITAL RECUPERADO POR VENTAS", isOscuro),
              _scrollableListContainer(
                children: _capitalPorVentaProds.isEmpty ? [_itemVacio("No hay capital recuperado de ventas aún.", isOscuro)]
                    : _capitalPorVentaProds.map((item) {
                        final int cant = (item['cantidad_total'] as num? ?? 0).toInt();
                        String nombreSnap = item['nombre_snapshot'].toString();
                        return _itemDesglose("$nombreSnap (x$cant)", (item['capital_recuperado'] as num).toDouble(), isOscuro, Icons.trending_up, onDelete: () => _eliminarCapitalRecuperadoConfirmacion(nombreSnap));
                      }).toList(),
              ),
              const Divider(height: 20, color: Colors.white24),
              _subtituloDesglose("COMPRAS DE STOCK / AJUSTES MANUALES", isOscuro),
              _scrollableListContainer(
                children: _capitalManualAjustes.isEmpty ? [_itemVacio("No hay ajustes manuales registrados.", isOscuro)]
                    : _capitalManualAjustes.map((ajuste) => _itemDesglose(ajuste['descripcion'] ?? "Ajuste sin descripción", (ajuste['monto'] as num).toDouble().abs(), isOscuro, Icons.shopping_bag_outlined, esGasto: (ajuste['monto'] as num).toDouble() >= 0, onDelete: () => _eliminarAjusteManualConfirmacion(ajuste))).toList(),
              ),
              const Divider(height: 20, color: Colors.white24),
              Row(
                children: [
                  Expanded(child: ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), padding: const EdgeInsets.symmetric(vertical: 11)), icon: const Icon(Icons.refresh_rounded, size: 16), label: const Text("REINICIAR", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)), onPressed: _reiniciarCapitalConfirmacion)),
                  const SizedBox(width: 10),
                  Expanded(child: ElevatedButton.icon(style: ElevatedButton.styleFrom(backgroundColor: Colors.orangeAccent, foregroundColor: Colors.black, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), padding: const EdgeInsets.symmetric(vertical: 11)), icon: const Icon(Icons.edit_rounded, size: 16), label: const Text("AJUSTAR", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)), onPressed: _ajustarCapitalManualDialogo)),
                ],
              ),
              const SizedBox(height: 10),
            ],
          ),
        )
      ],
    )
  );

  Widget _subtituloDesglose(String texto, bool isOscuro) => Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(texto, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: isOscuro ? Colors.amberAccent : Colors.white70)));
  Widget _itemVacio(String texto, bool isOscuro) => Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(texto, style: TextStyle(fontSize: 11, color: isOscuro ? Colors.white38 : Colors.white60, fontStyle: FontStyle.italic)));

  Widget _itemDesglose(String nombre, double monto, bool isOscuro, IconData icon, {bool esGasto = false, VoidCallback? onDelete}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6), 
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start, 
        children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon, size: 12, color: isOscuro ? Colors.white54 : Colors.white70)), const SizedBox(width: 8),
          Expanded(child: Text(nombre, style: TextStyle(color: isOscuro ? Colors.white70 : Colors.white, fontSize: 11, fontWeight: nombre.contains('(x') ? FontWeight.bold : FontWeight.normal, height: 1.2))),
          const SizedBox(width: 12),
          Text("${esGasto ? '-' : '+'}\$${monto.toStringAsFixed(0)}", style: TextStyle(color: esGasto ? (isOscuro ? Colors.redAccent : Colors.red.shade200) : (isOscuro ? Colors.greenAccent : Colors.white), fontWeight: FontWeight.bold, fontSize: 12)),
          if (onDelete != null) ...[const SizedBox(width: 12), GestureDetector(onTap: onDelete, child: const Icon(Icons.delete_outline_rounded, size: 14, color: Colors.redAccent))],
        ],
      ),
    );
  }
  
  Widget _cardInventario(String t, double m, Color c, List<Map<String, dynamic>> data, String campo, bool isOscuro) => Card(
    color: isOscuro ? Theme.of(context).cardColor : c, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: isOscuro ? c.withOpacity(0.4) : Colors.transparent)),
    child: ExpansionTile(
      iconColor: isOscuro ? c : Colors.white, collapsedIconColor: isOscuro ? c : Colors.white, title: Text(t, style: const TextStyle(color: Colors.white, fontSize: 13)), 
      subtitle: Text('\$${m.toStringAsFixed(0)}', style: TextStyle(color: isOscuro ? c : Colors.white, fontSize: 20, fontWeight: FontWeight.bold)), 
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: _scrollableListContainer(
            children: data.map((item) { 
              int stock = (item['stock_procesado'] ?? 0) as int;
              double pComp = (item['precio_compra'] as num? ?? 0).toDouble(); double pVent = (item['precio_venta'] as num? ?? 0).toDouble();
              double precio = (campo == 'compra') ? pComp : (pVent - pComp); double v = precio * stock;
              return ListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text(item['nombre'].toString(), style: TextStyle(color: isOscuro ? Colors.white70 : Colors.white, fontSize: 11)), trailing: Text('\$${v.toStringAsFixed(0)}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12))); 
            }).toList()
          ),
        )
      ]
    )
  );

  Widget _cardVentasMes(String t, double m, Color c, List<Map<String, dynamic>> data, String campo, {required bool esGanancia, required bool isOscuro}) => Card(
    color: isOscuro ? Theme.of(context).cardColor : c, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: isOscuro ? c.withOpacity(0.4) : Colors.transparent)),
    child: ExpansionTile(
      iconColor: isOscuro ? c : Colors.white, collapsedIconColor: isOscuro ? c : Colors.white, title: Text(t, style: const TextStyle(color: Colors.white, fontSize: 13)), 
      subtitle: Text('\$${m.toStringAsFixed(0)}', style: TextStyle(color: isOscuro ? c : Colors.white, fontSize: 20, fontWeight: FontWeight.bold)), 
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: _scrollableListContainer(
            children: data.map((item) { 
              double v = (item[campo] as num? ?? 0).toDouble();
              String nom = "${item['nombre_completo'] ?? ''}${ (item['nombre_negocio'] != null && item['nombre_negocio'].toString().isNotEmpty && item['nombre_negocio'] != 'null') ? ' (${item['nombre_negocio']})' : '' }";
              List<String> articulosList = List<String>.from(esGanancia ? (item['articulos_ganancia'] ?? []) : (item['articulos_recogido'] ?? []));
              return _FilaClienteExpandible(nombre: nom, valor: v, articulos: articulosList, isOscuro: isOscuro); 
            }).toList()
          ),
        )
      ]
    )
  );

  // 🔥 ACTUALIZADO: Botón con icono de escoba/basura para borrar todos los reportes de una categoría
  Widget _buildSeccionHistorial(String titulo, String prefijo, Color color, bool isOscuro, {String? excludePrefijo}) {
    final lista = _historialReportes.where((r) {
      final t = r['titulo'].toString();
      bool startsWithPrefijo = t.startsWith(prefijo);
      bool shouldExclude = excludePrefijo != null && t.startsWith(excludePrefijo);
      return startsWithPrefijo && !shouldExclude; 
    }).toList();
    
    if (lista.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 0, horizontal: 5), 
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(titulo, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: isOscuro ? color.withOpacity(0.5) : color.withOpacity(0.8))),
              IconButton(
                icon: const Icon(Icons.delete_sweep_rounded, color: Colors.redAccent, size: 20),
                tooltip: "Borrar todos",
                onPressed: () => _eliminarTodosReportesConfirmacion(titulo, lista),
              )
            ],
          )
        ),
        _scrollableListContainer(
          children: lista.map((r) => Card(
            color: Theme.of(context).cardColor, margin: const EdgeInsets.only(bottom: 8), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: isOscuro ? Colors.white10 : Colors.transparent)),
            child: ListTile(
              leading: Icon(Icons.picture_as_pdf, color: isOscuro ? color.withOpacity(0.7) : color),
              title: Text(r['titulo'].toString(), style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: isOscuro ? Colors.white : Colors.black87)),
              subtitle: Text("Recaudado: \$${(r['caja'] as num).toStringAsFixed(0)}", style: TextStyle(color: isOscuro ? Colors.white38 : Colors.black54)),
              onTap: () => _generarPdfProfesional(r),
              trailing: IconButton(icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 20), onPressed: () => _eliminarReporteConfirmacion(r)),
            ),
          )).toList()
        ),
        const SizedBox(height: 10),
      ],
    );
  }

  void _mostrarConfirmacion(String titulo, Function onConfirm) {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setSt) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)), title: Text(titulo, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [const Text("¿Generar este reporte en PDF ahora?"), if (_esPremiumUsuario) SwitchListTile(title: const Text("Incluir logo", style: TextStyle(fontSize: 13)), value: _incluirLogoEnReporte, onChanged: (v) => setSt(() => _incluirLogoEnReporte = v))]),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("CANCELAR")), ElevatedButton(onPressed: () { Navigator.pop(ctx); onConfirm(); }, child: const Text("SÍ, GENERAR"))],
        ),
      ),
    );
  }

  Future<void> _generarReporteMesBoton() async {
    final now = DateTime.now();
    final String tituloManual = "REPORTE-${_obtenerFechaFmt(now)} (${_formatearHoraPro(now)})";
    _mostrarConfirmacion(tituloManual, () async {
      if (!_esPremiumUsuario) { ServicioAnuncios.mostrarAnuncioIntersticial(() => _procederReporteMes(tituloManual)); } else { _procederReporteMes(tituloManual); }
    });
  }

  Future<void> _generarReporteRango() async {
    if (!_esPremiumUsuario) { Navigator.push(context, MaterialPageRoute(builder: (_) => const PantallaPremium())); return; }
    final DateTimeRange? range = await showDateRangePicker(context: context, firstDate: DateTime(2024), lastDate: DateTime.now().add(const Duration(days: 1)));
    if (range != null) {
      final String tituloRango = "REPORTE ${_obtenerFechaFmt(range.start)} A ${_obtenerFechaFmt(range.end)}";
      _mostrarConfirmacion(tituloRango, () async {
        final db = await DBHelper.instance.database;
        final start = range.start.toIso8601String().split('T')[0]; final end = range.end.toIso8601String().split('T')[0];
        final List<Map<String, dynamic>> peds = await db.rawQuery("SELECT p.fecha_hora, p.total_venta, (p.ganancia_total + COALESCE(p.valor_domicilio, 0)) as ganancia_real, COALESCE(c.nombre_completo, 'Cliente Temporal') as nombre_completo, c.nombre_negocio FROM pedidos p LEFT JOIN clientes c ON p.cliente_id = c.id WHERE p.estado = 'Completado' AND substr(p.fecha_hora, 1, 10) BETWEEN ? AND ?", [start, end]);
        
        if (peds.isEmpty) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Sin ventas en este rango."), backgroundColor: Colors.redAccent)); return; }
        double tC = 0, tU = 0; for (var p in peds) { tC += (p['total_venta'] as num? ?? 0).toDouble(); tU += (p['ganancia_real'] as num? ?? 0).toDouble(); }
        final rMap = {'titulo': tituloRango, 'fecha': DateTime.now().toIso8601String(), 'caja': tC, 'utilidad': tU, 'reinversion': (tC - tU), 'detalle_json': jsonEncode(peds), 'ultima_modificacion': DateTime.now().toIso8601String()};
        int id = await db.insert('reportes_guardados', rMap);
        ServicioNube.guardarReporteNube({...rMap, 'id': id});
        _generarPdfProfesional(rMap); _ejecutarMotorFinanciero();
      });
    }
  }

  String _obtenerFechaFmt(DateTime dt) => "${dt.day.toString().padLeft(2, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.year}";
  String _formatearHoraPro(DateTime n) { String p = n.hour >= 12 ? 'PM' : 'AM'; int h = n.hour > 12 ? n.hour - 12 : (n.hour == 0 ? 12 : n.hour); return "$h:${n.minute.toString().padLeft(2, '0')} $p"; }
}

class _FilaClienteExpandible extends StatefulWidget {
  final String nombre; final double valor; final List<String> articulos; final bool isOscuro;
  const _FilaClienteExpandible({required this.nombre, required this.valor, required this.articulos, required this.isOscuro});
  @override State<_FilaClienteExpandible> createState() => _FilaClienteExpandibleState();
}

class _FilaClienteExpandibleState extends State<_FilaClienteExpandible> {
  bool _expandido = false; 
  @override Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          dense: true, contentPadding: EdgeInsets.zero,
          title: Text(widget.nombre, style: TextStyle(color: widget.isOscuro ? Colors.white70 : Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [Text('\$${widget.valor.toStringAsFixed(0)}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)), const SizedBox(width: 4), Icon(_expandido ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded, size: 14, color: widget.isOscuro ? Colors.white38 : Colors.white70)]),
          onTap: () => setState(() => _expandido = !_expandido), 
        ),
        if (_expandido) Container(color: widget.isOscuro ? Colors.black26 : Colors.black12, width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: widget.articulos.map((art) => Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text(art, style: TextStyle(color: widget.isOscuro ? Colors.white38 : Colors.white70, fontSize: 10)))).toList()))
      ],
    );
  }
}