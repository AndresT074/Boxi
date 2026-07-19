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
import 'package:fl_chart/fl_chart.dart'; // 🔥 AÑADE ESTA LÍNEA AQUÍ

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
  // 🔥 VARIABLES ANALÍTICAS CON SOPORTE DE FECHAS COMPLETAS
  double _ventasDelDia = 0;
  int _pedidosDelDia = 0;
  int _filtroDiasEstancados = 10;
  List<Map<String, dynamic>> _topProductos = [];
  List<Map<String, dynamic>> _topClientes = [];
  List<Map<String, dynamic>> _productosEstancados = [];
  
  // Filtros independientes
  String _filtroVentas = 'Semana'; 
  String _filtroPedidos = 'Semana'; 
  String _filtroRankings = 'Semana'; 
  int _limiteRankings = 5; 
  String _tipoRanking = 'Productos'; 

  // Gráficos de Ventas ($)
  List<FlSpot> _spotsPeriodoActual = [];
  List<FlSpot> _spotsPeriodoPrevio = [];
  List<String> _ejeXEtiquetas = [];
  List<String> _ejeXEtiquetasCompletas = []; // 🔥 Fechas reales para tooltips
  double _maxYGrafico = 100;

  // Gráfico de Pedidos (#)
  List<BarChartGroupData> _barGroupsPedidos = [];
  List<String> _ejeXPedidosEtiquetas = [];
  List<String> _ejeXPedidosEtiquetasCompletas = []; // 🔥 Fechas reales para tooltips
  double _maxYPedidosGrafico = 10;

  // Variables de Retención
  Map<String, Map<String, int>> _retencionClientes = {
    '15': {'activos': 0, 'inactivos': 0},
    '30': {'activos': 0, 'inactivos': 0},
    '60': {'activos': 0, 'inactivos': 0},
  };

  bool _cargandoGraficos = true;

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
    await _cargarDatosGraficos(); // 🔥 Carga de analíticas al iniciar
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
        _cargarDatosGraficos(); 
      });
    }

    // 🔥 REEMPLAZAR TODAS LAS SUSCRIPCIONES POR ESTA:
    final subs = ServicioNube.escucharCambiosNubeRTDB(() async {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) {
        await ServicioNube.descargarSoloModificados(uid, 'productos', 'ultima_modificacion');
        await ServicioNube.descargarSoloModificados(uid, 'pedidos', 'ultima_modificacion');
        await ServicioNube.descargarSoloModificados(uid, 'ajustes_capital', 'ultima_modificacion');
        await ServicioNube.descargarSoloModificados(uid, 'reportes_guardados', 'ultima_modificacion');
        recalcularConDebounce();
      }
    });
    
    if (subs != null) _suscripciones.add(subs);
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

      // 2. CAPITAL GLOBAL CON FECHA ASOCIADA POR TRANSACCIÓN (Últimos 150 registros)
      final capitalVentasRaw = await db.rawQuery('''
        SELECT d.nombre_snapshot, d.cantidad as cantidad_total, p.fecha_hora as fecha,
               (d.cantidad * (SELECT precio_compra FROM productos WHERE id = d.producto_id)) as capital_recuperado
        FROM detalle_pedidos d JOIN pedidos p ON d.pedido_id = p.id
        WHERE p.estado = 'Completado' AND (d.cantidad * (SELECT precio_compra FROM productos WHERE id = d.producto_id)) > 0
        ORDER BY p.fecha_hora DESC
        LIMIT 150
      ''');

      // LÍMITE DE MEMORIA: Solo los últimos 150 ajustes manuales
      final ajustesManuales = await db.query('ajustes_capital', columns: ['id', 'monto', 'descripcion', 'fecha'], orderBy: 'id DESC', limit: 150);

      final totalRecuperadoVentas = await db.rawQuery("SELECT SUM(cantidad * (SELECT precio_compra FROM productos WHERE id = producto_id)) as total FROM detalle_pedidos WHERE pedido_id IN (SELECT id FROM pedidos WHERE estado = 'Completado')");
      final totalGastadoQ = await db.rawQuery("SELECT SUM(monto) as total FROM ajustes_capital");
      
      double capRecup = (totalRecuperadoVentas.first['total'] as num? ?? 0).toDouble();
      double capAjust = (totalGastadoQ.first['total'] as num? ?? 0).toDouble();
      double capitalDispo = capRecup - capAjust;

      // 3. MÉTRICAS DEL MES (Filtradas por fecha de pago)
      final metricasMes = await db.rawQuery(
          "SELECT SUM(total_venta) as cajaMes, SUM(ganancia_total + COALESCE(valor_domicilio, 0)) as utilMes FROM pedidos WHERE estado = 'Completado' AND substr(COALESCE(fecha_pago, fecha_hora), 1, 7) = ?", 
          [mesActualStr]
      );
      double cajaMes = (metricasMes.first['cajaMes'] as num? ?? 0).toDouble();
      double utilMes = (metricasMes.first['utilMes'] as num? ?? 0).toDouble();

      // 4. DESGLOSE DETALLADO POR CLIENTE (Filtrado por fecha de pago)
      final clientesRaw = await db.rawQuery('''
        SELECT c.id as cliente_id, COALESCE(c.nombre_completo, 'Cliente Temporal') as nombre_completo, c.nombre_negocio,
               SUM(p.total_venta) as recaudado, SUM(p.ganancia_total + COALESCE(p.valor_domicilio, 0)) as ganancia_neta, SUM(COALESCE(p.valor_domicilio, 0)) as total_domicilios
        FROM pedidos p LEFT JOIN clientes c ON p.cliente_id = c.id
        WHERE p.estado = 'Completado' AND substr(COALESCE(p.fecha_pago, p.fecha_hora), 1, 7) = ? GROUP BY p.cliente_id
      ''', [mesActualStr]);

      List<Map<String, dynamic>> desgloseMesDefinitivo = [];
      for (var c in clientesRaw) {
        final itemsAgrupados = await db.rawQuery('''
          SELECT d.nombre_snapshot, SUM(d.cantidad) as total_cant, d.descuento, d.precio_unitario, (SELECT precio_compra FROM productos WHERE id = d.producto_id) as p_compra
          FROM detalle_pedidos d JOIN pedidos p ON d.pedido_id = p.id
          WHERE p.cliente_id = ? AND p.estado = 'Completado' AND substr(COALESCE(p.fecha_pago, p.fecha_hora), 1, 7) = ?
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

      // Máximo 150 reportes históricos en RAM sin la columna gigante de JSON.
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

    // 1. VENTAS COMPLETADAS (Ventas cobradas en el mes filtrado)
    final List<Map<String, dynamic>> peds = await db.rawQuery('''
      SELECT p.fecha_hora, p.fecha_pago, p.total_venta, (p.ganancia_total + COALESCE(p.valor_domicilio, 0)) as ganancia_real, c.nombre_completo, c.nombre_negocio
      FROM pedidos p LEFT JOIN clientes c ON p.cliente_id = c.id
      WHERE p.estado = 'Completado' AND substr(COALESCE(p.fecha_pago, p.fecha_hora), 1, 7) = ?
    ''', [mesTarget]);

    // 2. RECONSTRUCCIÓN GENERAL DEL LIBRO MAYOR (Todos los tiempos para cálculo exacto antes/después)
    final List<Map<String, dynamic>> todasVentas = await db.rawQuery('''
      SELECT p.id as id_ref, p.fecha_hora, 
             SUM(d.cantidad * COALESCE((SELECT precio_compra FROM productos WHERE id = d.producto_id), 0)) as monto
      FROM detalle_pedidos d JOIN pedidos p ON d.pedido_id = p.id
      WHERE p.estado = 'Completado'
      GROUP BY p.id, p.fecha_hora
    ''');

    final List<Map<String, dynamic>> todosAjustes = await db.rawQuery('''
      SELECT id as id_ref, fecha as fecha_hora, monto, descripcion FROM ajustes_capital
    ''');

    List<Map<String, dynamic>> libroMayor = [];
    
    // Sumar capital recuperado de ventas
    for (var v in todasVentas) {
      double m = (v['monto'] as num? ?? 0).toDouble();
      if (m > 0) {
        libroMayor.add({
          'fecha_hora': v['fecha_hora'],
          'monto': m, // Sube capital (+)
          'descripcion': 'Capital recuperado de venta (Pedido #${v['id_ref']})',
        });
      }
    }
    
    // Sumar/Restar egresos e ingresos manuales
    for (var a in todosAjustes) {
      double m = (a['monto'] as num? ?? 0).toDouble();
      libroMayor.add({
        'fecha_hora': a['fecha_hora'],
        'monto': -m, // Egreso resta capital (-), Ingreso suma capital (+)
        'descripcion': a['descripcion'] ?? 'Ajuste manual',
      });
    }

    // Ordenar de más antiguo a más nuevo para la contabilidad
    libroMayor.sort((a, b) => a['fecha_hora'].toString().compareTo(b['fecha_hora'].toString()));

    double saldoAcumulado = 0.0;
    List<Map<String, dynamic>> libroMayorConSaldos = [];
    
    for (var item in libroMayor) {
      double antes = saldoAcumulado;
      double impacto = (item['monto'] as num).toDouble();
      saldoAcumulado += impacto;
      double despues = saldoAcumulado;

      libroMayorConSaldos.add({
        ...item,
        'antes': antes,
        'despues': despues,
      });
    }

    // Filtrar los movimientos que corresponden SOLAMENTE al mes target
    final listAjustesMes = libroMayorConSaldos.where((item) {
      final fh = item['fecha_hora'].toString();
      return fh.length >= 7 && fh.substring(0, 7) == mesTarget;
    }).toList();

    if (peds.isEmpty && listAjustesMes.isEmpty) {
      if (manual && mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Sin movimientos financieros para este mes."), backgroundColor: Colors.orange));
      return;
    }

    double totalVentasCaja = 0;
    double totalVentasUtilidad = 0;
    for (var p in peds) {
      totalVentasCaja += (p['total_venta'] as num? ?? 0).toDouble();
      totalVentasUtilidad += (p['ganancia_real'] as num? ?? 0).toDouble();
    }

    final reporteMap = {
      'titulo': titulo, 
      'fecha': now.toIso8601String(),
      'caja': totalVentasCaja, 
      'utilidad': totalVentasUtilidad, 
      'reinversion': capitalGlobalReinversion, // Capital actual de re-inversión global real
      'detalle_json': jsonEncode({
        'ventas': peds,
        'ajustes': listAjustesMes, // Guardamos la lista ordenada con antes/después
        'capital_actual': capitalGlobalReinversion,
      }), 
      'ultima_modificacion': now.toIso8601String(),
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

    List<dynamic> ventas = [];
    List<dynamic> ajustes = [];
    double capitalActualReporte = (r['reinversion'] as num? ?? 0).toDouble();

    if (jsonStr.isNotEmpty) {
      try {
        final decoded = jsonDecode(jsonStr);
        if (decoded is Map) {
          ventas = decoded['ventas'] ?? [];
          ajustes = decoded['ajustes'] ?? [];
          if (decoded.containsKey('capital_actual')) {
            capitalActualReporte = (decoded['capital_actual'] as num).toDouble();
          }
        } else if (decoded is List) {
          // Retrocompatibilidad con reportes viejos que solo tenían lista
          ventas = decoded;
        }
      } catch (_) {}
    }

    // 🔥 ENVIAMOS LAS TABLAS COMPLETAMENTE SEPARADAS
    await ServicioPdf.compartirReporte(
      titulo: r['titulo'].toString(), 
      totalCaja: (r['caja'] as num).toDouble(), // Caja real de ventas
      totalUtilidad: (r['utilidad'] as num).toDouble(), // Utilidad real de ventas
      ventas: ventas, // Solo ventas reales
      nombreNegocio: nombreNeg, 
      logoPath: logoPath,
      mostrarLogo: _esPremiumUsuario && _incluirLogoEnReporte,
      ajustes: ajustes, // 🔥 NUEVO: Ajustes enviados de forma aislada
      capitalReinversion: capitalActualReporte, // 🔥 NUEVO: Capital global del reporte
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

    return DefaultTabController(
      length: 2, 
      child: Scaffold(
        backgroundColor: isOscuro ? const Color(0xFF0A0A0F) : const Color(0xFFF5F7FA),
        appBar: AppBar(
          title: const Text('CENTRO FINANCIERO', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          backgroundColor: isOscuro ? const Color(0xFF0D1B2A) : const Color(0xFF0D47A1), 
          foregroundColor: Colors.white,
          actions: [
            IconButton(icon: const Icon(Icons.calendar_month), onPressed: _generarReporteRango),
            IconButton(icon: const Icon(Icons.picture_as_pdf, color: Colors.orangeAccent), onPressed: _generarReporteMesBoton),
          ],
          bottom: const TabBar(
            indicatorColor: Colors.cyanAccent,
            labelColor: Colors.cyanAccent,
            unselectedLabelColor: Colors.white60,
            tabs: [
              Tab(icon: Icon(Icons.account_balance_wallet_rounded), text: "FINANZAS"),
              Tab(icon: Icon(Icons.bar_chart_rounded), text: "ESTADÍSTICAS"),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildTabFinanzas(isOscuro),
            _buildTabGraficos(isOscuro),
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
      title: Text("Capital de Reinversión Actual (Fondo para Stock)", style: TextStyle(color: isOscuro ? Colors.white70 : Colors.white, fontSize: 13, fontWeight: FontWeight.bold)), 
      subtitle: Text('\$${m.toStringAsFixed(0)}', style: TextStyle(color: isOscuro ? c : Colors.white, fontSize: 24, fontWeight: FontWeight.w900)),
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10), decoration: BoxDecoration(color: isOscuro ? Colors.black26 : Colors.white.withOpacity(0.1)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _subtituloDesglose("CAPITAL RECUPERADO DE VENTAS", isOscuro),
              _scrollableListContainer(
                children: _capitalPorVentaProds.isEmpty ? [_itemVacio("No hay capital recuperado de ventas aún.", isOscuro)]
                    : _capitalPorVentaProds.map((item) {
                        final int cant = (item['cantidad_total'] as num? ?? 0).toInt();
                        String nombreSnap = item['nombre_snapshot'].toString();
                        String fechaFmt = item['fecha'] != null ? _formatearFechaCorta(item['fecha'].toString()) : '';
                        return _itemDesglose(
                          "$nombreSnap (x$cant)\n$fechaFmt", 
                          (item['capital_recuperado'] as num).toDouble(), 
                          isOscuro, 
                          Icons.trending_up, 
                          onDelete: () => _eliminarCapitalRecuperadoConfirmacion(nombreSnap)
                        );
                      }).toList(),
              ),
              const Divider(height: 20, color: Colors.white24),
              _subtituloDesglose("COMPRAS DE STOCK / REINVERSIONES / INGRESO - EGRESO", isOscuro),
              _scrollableListContainer(
                children: _capitalManualAjustes.isEmpty ? [_itemVacio("No hay movimientos manuales registrados.", isOscuro)]
                    : _capitalManualAjustes.map((ajuste) {
                        String desc = ajuste['descripcion'] ?? "Ajuste manual";
                        String fechaFmt = ajuste['fecha'] != null ? _formatearFechaCorta(ajuste['fecha'].toString()) : '';
                        double monto = (ajuste['monto'] as num).toDouble();
                        return _itemDesglose(
                          "$desc\n$fechaFmt", 
                          monto.abs(), 
                          isOscuro, 
                          monto >= 0 ? Icons.remove_circle_outline : Icons.add_circle_outline, 
                          esGasto: monto >= 0, 
                          onDelete: () => _eliminarAjusteManualConfirmacion(ajuste)
                        );
                      }).toList(),
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
        final start = range.start.toIso8601String().split('T')[0]; 
        final end = range.end.toIso8601String().split('T')[0];
        final List<Map<String, dynamic>> peds = await db.rawQuery('''
          SELECT p.fecha_hora, p.total_venta, (p.ganancia_total + COALESCE(p.valor_domicilio, 0)) as ganancia_real, COALESCE(c.nombre_completo, 'Cliente Temporal') as nombre_completo, c.nombre_negocio 
          FROM pedidos p LEFT JOIN clientes c ON p.cliente_id = c.id 
          WHERE p.estado = 'Completado' AND substr(p.fecha_hora, 1, 10) BETWEEN ? AND ?
        ''', [start, end]);
        final List<Map<String, dynamic>> todasVentas = await db.rawQuery('''
          SELECT p.id as id_ref, p.fecha_hora, 
                 SUM(d.cantidad * COALESCE((SELECT precio_compra FROM productos WHERE id = d.producto_id), 0)) as monto
          FROM detalle_pedidos d JOIN pedidos p ON d.pedido_id = p.id
          WHERE p.estado = 'Completado'
          GROUP BY p.id, p.fecha_hora
        ''');
        final List<Map<String, dynamic>> todosAjustes = await db.rawQuery('''
          SELECT id as id_ref, fecha as fecha_hora, monto, descripcion FROM ajustes_capital
        ''');
        List<Map<String, dynamic>> libroMayor = [];
        for (var v in todasVentas) {
          double m = (v['monto'] as num? ?? 0).toDouble();
          if (m > 0) {
            libroMayor.add({
              'fecha_hora': v['fecha_hora'],
              'monto': m,
              'descripcion': 'Recuperación capital de venta (Pedido #${v['id_ref']})',
            });
          }
        }
        for (var a in todosAjustes) {
          double m = (a['monto'] as num? ?? 0).toDouble();
          libroMayor.add({
            'fecha_hora': a['fecha_hora'],
            'monto': -m,
            'descripcion': a['descripcion'] ?? 'Ajuste manual',
          });
        }
        libroMayor.sort((a, b) => a['fecha_hora'].toString().compareTo(b['fecha_hora'].toString()));
        double saldoAcumulado = 0.0;
        List<Map<String, dynamic>> libroMayorConSaldos = [];
        for (var item in libroMayor) {
          double antes = saldoAcumulado;
          double impacto = (item['monto'] as num).toDouble();
          saldoAcumulado += impacto;
          double despues = saldoAcumulado;
          libroMayorConSaldos.add({
            ...item,
            'antes': antes,
            'despues': despues,
          });
        }
        
        final listAjustesRango = libroMayorConSaldos.where((item) {
          final fh = item['fecha_hora'].toString();
          if (fh.length < 10) return false;
          final fechaDia = fh.substring(0, 10);
          return fechaDia.compareTo(start) >= 0 && fechaDia.compareTo(end) <= 0;
        }).toList();
        if (peds.isEmpty && listAjustesRango.isEmpty) { 
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Sin movimientos en este rango."), backgroundColor: Colors.redAccent)); 
          return; 
        }
        double totalVentasCaja = 0;
        double totalVentasUtilidad = 0;
        for (var p in peds) { 
          totalVentasCaja += (p['total_venta'] as num? ?? 0).toDouble(); 
          totalVentasUtilidad += (p['ganancia_real'] as num? ?? 0).toDouble(); 
        }
        final rMap = {
          'titulo': tituloRango, 
          'fecha': DateTime.now().toIso8601String(), 
          'caja': totalVentasCaja, 
          'utilidad': totalVentasUtilidad, 
          'reinversion': capitalGlobalReinversion, 
          'detalle_json': jsonEncode({
            'ventas': peds,
            'ajustes': listAjustesRango,
            'capital_actual': capitalGlobalReinversion,
          }), 
          'ultima_modificacion': DateTime.now().toIso8601String()
        };
        int id = await db.insert('reportes_guardados', rMap);
        ServicioNube.guardarReporteNube({...rMap, 'id': id});
        _generarPdfProfesional(rMap); 
        _ejecutarMotorFinanciero();
      });
    }
  }
  
  String _formatearFechaCorta(String fechaIso) {
    try {
      final dt = DateTime.parse(fechaIso);
      return "${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year} ${_formatearHoraPro(dt)}";
    } catch (_) {
      return fechaIso;
    }
  }
  String _obtenerFechaFmt(DateTime dt) => "${dt.day.toString().padLeft(2, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.year}";
  String _formatearHoraPro(DateTime n) { String p = n.hour >= 12 ? 'PM' : 'AM'; int h = n.hour > 12 ? n.hour - 12 : (n.hour == 0 ? 12 : n.hour); return "$h:${n.minute.toString().padLeft(2, '0')} $p"; }
  // =========================================================================
  // 🔥 MOTOR DE ANALÍTICA AVANZADA (100% OFFLINE, 0 LECTURAS FIREBASE)
  // =========================================================================
  Future<void> _cargarDatosGraficos() async {
    try {
      final Database db = await DBHelper.instance.database;
      final now = DateTime.now();
      final hoyStr = "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";

      // 1. VENTAS Y PEDIDOS DEL DÍA (Filtrados por la fecha de pago real)
      final qVentasDia = await db.rawQuery(
          "SELECT SUM(total_venta) as total FROM pedidos WHERE estado = 'Completado' AND substr(COALESCE(fecha_pago, fecha_hora), 1, 10) = ?", 
          [hoyStr]
      );
      final qPedsDia = await db.rawQuery(
          "SELECT COUNT(id) as c FROM pedidos WHERE estado = 'Completado' AND substr(COALESCE(fecha_pago, fecha_hora), 1, 10) = ?", 
          [hoyStr]
      );
      double vDia = (qVentasDia.first['total'] as num? ?? 0).toDouble();
      int pDia = Sqflite.firstIntValue(qPedsDia) ?? 0;

      // 2. PARÁMETROS DE TIEMPO DINÁMICOS
      DateTime dateInicioRankings = now.subtract(Duration(days: _filtroRankings == 'Semana' ? 6 : (_filtroRankings == 'Mes' ? (now.day - 1) : 365)));
      String inicioRankingsStr = dateInicioRankings.toIso8601String().substring(0, 10);

      // 3. RANKINGS (Productos vs Variantes)
      String queryProds = _tipoRanking == 'Productos' 
          ? '''
            SELECT (SELECT nombre FROM productos WHERE id = d.producto_id) as nombre, SUM(d.cantidad) as total_vendido, COUNT(DISTINCT d.pedido_id) as total_pedidos
            FROM detalle_pedidos d JOIN pedidos p ON d.pedido_id = p.id 
            WHERE p.estado = 'Completado' AND substr(p.fecha_hora, 1, 10) >= ?
            GROUP BY d.producto_id 
            ORDER BY total_vendido DESC LIMIT $_limiteRankings
          '''
          : '''
            SELECT d.nombre_snapshot as nombre, SUM(d.cantidad) as total_vendido, COUNT(DISTINCT d.pedido_id) as total_pedidos
            FROM detalle_pedidos d JOIN pedidos p ON d.pedido_id = p.id 
            WHERE p.estado = 'Completado' AND substr(p.fecha_hora, 1, 10) >= ?
            GROUP BY d.nombre_snapshot 
            ORDER BY total_vendido DESC LIMIT $_limiteRankings
          ''';

      final qTopProds = await db.rawQuery(queryProds, [inicioRankingsStr]);

      final qTopClientes = await db.rawQuery('''
        SELECT COALESCE(c.nombre_completo, 'Cliente General') as nombre, SUM(p.total_venta) as gastado, COUNT(p.id) as total_pedidos
        FROM pedidos p LEFT JOIN clientes c ON p.cliente_id = c.id 
        WHERE p.estado = 'Completado' AND substr(p.fecha_hora, 1, 10) >= ?
        GROUP BY p.cliente_id 
        ORDER BY gastado DESC LIMIT $_limiteRankings
      ''', [inicioRankingsStr]);

      // 4. RETENCIÓN DE CLIENTES COMPARATIVA (15, 30 y 60 DÍAS)
      final qTotalClientes = await db.rawQuery("SELECT COUNT(id) as total FROM clientes");
      int totalClientesApp = Sqflite.firstIntValue(qTotalClientes) ?? 0;

      Map<String, Map<String, int>> retencionFmt = {};
      List<int> rangosDias = [15, 30, 60];
      for (int dias in rangosDias) {
        String limiteFecha = now.subtract(Duration(days: dias)).toIso8601String().substring(0, 10);
        final qActivos = await db.rawQuery("SELECT COUNT(DISTINCT cliente_id) as c FROM pedidos WHERE estado = 'Completado' AND substr(fecha_hora, 1, 10) >= ?", [limiteFecha]);
        int activos = Sqflite.firstIntValue(qActivos) ?? 0;
        int inactivos = (totalClientesApp - activos).clamp(0, totalClientesApp);
        retencionFmt[dias.toString()] = {'activos': activos, 'inactivos': inactivos};
      }

      // 5. INVENTARIO ESTANCADO (Días dinámicos: 10, 20 o 30 días)
      final haceXDias = now.subtract(Duration(days: _filtroDiasEstancados)).toIso8601String().substring(0, 10);
      final qEstancados = await db.rawQuery('''
        SELECT nombre, stock 
        FROM productos 
        WHERE activo = 1 AND stock > 0 AND id NOT IN (
          SELECT producto_id FROM detalle_pedidos d JOIN pedidos p ON d.pedido_id = p.id 
          WHERE p.estado = 'Completado' AND substr(p.fecha_hora, 1, 10) >= ?
        )
        ORDER BY stock DESC 
      ''', [haceXDias]);
      // 6. CÁLCULO DE GRÁFICOS
      List<FlSpot> spotsActual = [];
      List<FlSpot> spotsPrevio = [];
      List<BarChartGroupData> barGroupsPedidos = [];
      List<String> etiquetasX = [];
      List<String> etiquetasXCompletas = [];
      List<String> etiquetasXPedidos = [];
      List<String> etiquetasXPedidosCompletas = [];
      double maxValorVentas = 100;
      double maxValorPedidos = 5;

      DateTime startVentasAct;
      DateTime startVentasPre;
      int diasVentas = 0;

      if (_filtroVentas == 'Semana') {
        diasVentas = 7;
        startVentasAct = now.subtract(const Duration(days: 6));
        startVentasPre = now.subtract(const Duration(days: 13));
      } else if (_filtroVentas == 'Mes') {
        diasVentas = now.day; 
        startVentasAct = DateTime(now.year, now.month, 1);
        startVentasPre = DateTime(now.year, now.month - 1, 1);
      } else {
        diasVentas = 12;
        startVentasAct = DateTime(now.year - 1, now.month + 1, 1);
        startVentasPre = DateTime(now.year - 2, now.month + 1, 1);
      }

      if (_filtroVentas == 'Semana' || _filtroVentas == 'Mes') {
        for (int i = 0; i < diasVentas; i++) {
          DateTime dAct = startVentasAct.add(Duration(days: i));
          DateTime dPre = startVentasPre.add(Duration(days: i));

          final qActV = await db.rawQuery("SELECT SUM(total_venta) as t FROM pedidos WHERE estado = 'Completado' AND substr(fecha_hora, 1, 10) = ?", [dAct.toIso8601String().substring(0, 10)]);
          final qPreV = await db.rawQuery("SELECT SUM(total_venta) as t FROM pedidos WHERE estado = 'Completado' AND substr(fecha_hora, 1, 10) = ?", [dPre.toIso8601String().substring(0, 10)]);

          double valActV = (qActV.first['t'] as num? ?? 0).toDouble();
          double valPreV = (qPreV.first['t'] as num? ?? 0).toDouble();

          spotsActual.add(FlSpot(i.toDouble(), valActV));
          spotsPrevio.add(FlSpot(i.toDouble(), valPreV));

          if (valActV > maxValorVentas) maxValorVentas = valActV;
          if (valPreV > maxValorVentas) maxValorVentas = valPreV;

          // 🔥 CORREGIDO: Tooltip muestra nombre de día completo para Semana y fecha para Mes
          if (_filtroVentas == 'Semana') {
            String diaSem = ["Lunes","Martes","Miércoles","Jueves","Viernes","Sábado","Domingo"][dAct.weekday-1];
            etiquetasXCompletas.add(diaSem);
            etiquetasX.add(["Lun","Mar","Mié","Jue","Vie","Sáb","Dom"][dAct.weekday-1]);
          } else {
            etiquetasXCompletas.add("${dAct.day}/${dAct.month}");
            etiquetasX.add("${dAct.day}/${dAct.month}");
          }
        }
      } else {
        // Año agrupado por meses
        for (int i = 0; i < 12; i++) {
          DateTime mAct = DateTime(startVentasAct.year, startVentasAct.month + i, 1);
          DateTime mPre = DateTime(startVentasPre.year, startVentasPre.month + i, 1);

          final qActV = await db.rawQuery("SELECT SUM(total_venta) as t FROM pedidos WHERE estado = 'Completado' AND substr(fecha_hora, 1, 7) = ?", ["${mAct.year}-${mAct.month.toString().padLeft(2, '0')}"]);
          final qPreV = await db.rawQuery("SELECT SUM(total_venta) as t FROM pedidos WHERE estado = 'Completado' AND substr(fecha_hora, 1, 7) = ?", ["${mPre.year}-${mPre.month.toString().padLeft(2, '0')}"]);

          double valActV = (qActV.first['t'] as num? ?? 0).toDouble();
          double valPreV = (qPreV.first['t'] as num? ?? 0).toDouble();

          spotsActual.add(FlSpot(i.toDouble(), valActV));
          spotsPrevio.add(FlSpot(i.toDouble(), valPreV));

          if (valActV > maxValorVentas) maxValorVentas = valActV;
          if (valPreV > maxValorVentas) maxValorVentas = valPreV;

          String nomMes = ["Enero","Febrero","Marzo","Abril","Mayo","Junio","Julio","Agosto","Septiembre","Octubre","Noviembre","Diciembre"][mAct.month-1];
          etiquetasXCompletas.add(nomMes);
          etiquetasX.add(["Ene","Feb","Mar","Abr","May","Jun","Jul","Ago","Sep","Oct","Nov","Dic"][mAct.month-1]);
        }
      }

      // 7. GRÁFICO DE PEDIDOS (#)
      DateTime startPeds;
      int diasPeds = 0;

      if (_filtroPedidos == 'Semana') {
        diasPeds = 7;
        startPeds = now.subtract(const Duration(days: 6));
      } else if (_filtroPedidos == 'Mes') {
        diasPeds = now.day;
        startPeds = DateTime(now.year, now.month, 1);
      } else {
        diasPeds = 12;
        startPeds = DateTime(now.year - 1, now.month + 1, 1);
      }

      if (_filtroPedidos == 'Semana' || _filtroPedidos == 'Mes') {
        for (int i = 0; i < diasPeds; i++) {
          DateTime dAct = startPeds.add(Duration(days: i));
          final qActP = await db.rawQuery("SELECT COUNT(id) as c FROM pedidos WHERE estado = 'Completado' AND substr(fecha_hora, 1, 10) = ?", [dAct.toIso8601String().substring(0, 10)]);
          double valP = (qActP.first['c'] as num? ?? 0).toDouble();

          barGroupsPedidos.add(BarChartGroupData(
            x: i,
            barRods: [BarChartRodData(toY: valP, color: Colors.blueAccent, width: _filtroPedidos == 'Semana' ? 12 : 6, borderRadius: BorderRadius.circular(2))]
          ));

          if (valP > maxValorPedidos) maxValorPedidos = valP;

          // 🔥 CORREGIDO: Se añaden todas las fechas de volumen consecutivas
          etiquetasXPedidosCompletas.add("${dAct.day}/${dAct.month}");

          if (_filtroPedidos == 'Semana') {
            String diaSem = ["Lunes","Martes","Miércoles","Jueves","Viernes","Sábado","Domingo"][dAct.weekday-1];
            etiquetasXPedidosCompletas[i] = diaSem; // Guardar nombre de día para tooltip
            etiquetasXPedidos.add(["Lun","Mar","Mié","Jue","Vie","Sáb","Dom"][dAct.weekday-1]);
          } else {
            etiquetasXPedidos.add("${dAct.day}/${dAct.month}"); // Se muestran todas consecutivas rotadas
          }
        }
      } else {
        for (int i = 0; i < 12; i++) {
          DateTime mAct = DateTime(startPeds.year, startPeds.month + i, 1);
          final qActP = await db.rawQuery("SELECT COUNT(id) as c FROM pedidos WHERE estado = 'Completado' AND substr(fecha_hora, 1, 7) = ?", ["${mAct.year}-${mAct.month.toString().padLeft(2, '0')}"]);
          double valP = (qActP.first['c'] as num? ?? 0).toDouble();

          barGroupsPedidos.add(BarChartGroupData(
            x: i,
            barRods: [BarChartRodData(toY: valP, color: Colors.blueAccent, width: 10, borderRadius: BorderRadius.circular(2))]
          ));

          if (valP > maxValorPedidos) maxValorPedidos = valP;
          
          String nomMes = ["Enero","Febrero","Marzo","Abril","Mayo","Junio","Julio","Agosto","Septiembre","Octubre","Noviembre","Diciembre"][mAct.month-1];
          etiquetasXPedidosCompletas.add(nomMes);
          etiquetasXPedidos.add(["Ene","Feb","Mar","Abr","May","Jun","Jul","Ago","Sep","Oct","Nov","Dic"][mAct.month-1]);
        }
      }

      if (mounted) {
        setState(() {
          _ventasDelDia = vDia;
          _pedidosDelDia = pDia;
          _topProductos = qTopProds;
          _topClientes = qTopClientes;
          _productosEstancados = qEstancados;
          _retencionClientes = retencionFmt;
          _spotsPeriodoActual = spotsActual;
          _spotsPeriodoPrevio = spotsPrevio;
          _ejeXEtiquetas = etiquetasX;
          _ejeXEtiquetasCompletas = etiquetasXCompletas; 
          _barGroupsPedidos = barGroupsPedidos;
          _ejeXPedidosEtiquetas = etiquetasXPedidos;
          _ejeXPedidosEtiquetasCompletas = etiquetasXPedidosCompletas; 
          _maxYGrafico = maxValorVentas * 1.15;
          _maxYPedidosGrafico = maxValorPedidos + 1;
          _cargandoGraficos = false;
        });
      }
    } catch (e) {
      debugPrint("Error motor analítico: $e");
    }
  }

  Widget _buildTabFinanzas(bool isOscuro) {
    return SingleChildScrollView(
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
    );
  }
  
  Widget _buildTabGraficos(bool isOscuro) {
    if (_cargandoGraficos) return const Center(child: CircularProgressIndicator());

    return SingleChildScrollView(
      padding: const EdgeInsets.all(15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. HEADER: VENTAS DEL DÍA
          Container(
            width: double.infinity, padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: isOscuro 
                    ? [const Color(0xFF1E3A8A), const Color(0xFF0F172A)] 
                    : [const Color(0xFF2563EB), const Color(0xFF3B82F6)]
              ),
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: isOscuro ? Colors.black54 : Colors.blue.withOpacity(0.3), 
                  blurRadius: 12, 
                  offset: const Offset(0, 4)
                )
              ]
            ),
            child: Column(
              children: [
                Text(
                  "VENTAS DE HOY", 
                  style: TextStyle(
                    color: isOscuro ? Colors.white60 : Colors.white.withOpacity(0.9), 
                    fontSize: 12, 
                    fontWeight: FontWeight.bold, 
                    letterSpacing: 1.5
                  )
                ),
                const SizedBox(height: 6),
                Text(
                  "\$${_ventasDelDia.toStringAsFixed(0)}", 
                  style: const TextStyle(color: Colors.white, fontSize: 36, fontWeight: FontWeight.w900)
                ),
                const SizedBox(height: 4),
                Text(
                  "$_pedidosDelDia ${_pedidosDelDia == 1 ? 'pedido registrado' : 'pedidos registrados hoy'}",
                  style: TextStyle(color: isOscuro ? Colors.cyanAccent : Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)
                ),
              ],
            ),
          ),
          const SizedBox(height: 25),

          // 2. EVOLUCIÓN DE VENTAS (Con su propio filtro independiente y sin recargas globales)
          _tituloConFiltro(
            "Evolución de Ventas (\$)", 
            Icons.trending_up, 
            _filtroVentas, 
            isOscuro,
            (v) {
              if (v != null) {
                setState(() { _filtroVentas = v; }); 
                _cargarDatosGraficos();
              }
            }
          ),
          Card(
            color: isOscuro ? Theme.of(context).cardColor : Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            elevation: isOscuro ? 0 : 2,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 20, 20, 15),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _indicadorLinea(Colors.blueAccent, _filtroVentas == 'Semana' ? "Esta Semana" : (_filtroVentas == 'Mes' ? "Este Mes" : "Este Año")),
                      const SizedBox(width: 20),
                      _indicadorLinea(Colors.blue.withOpacity(0.4), _filtroVentas == 'Semana' ? "Sem. Anterior" : (_filtroVentas == 'Mes' ? "Mes Anterior" : "Año Anterior")),
                    ],
                  ),
                  const SizedBox(height: 15),
                  SizedBox(
                    height: 220,
                    child: LineChart(
                      LineChartData(
                        maxY: _maxYGrafico,
                        minY: 0,
                        // 🔥 MARGEN DE SEGURIDAD EXTREMO: El punto inicial y final tienen espacio para respirar
                        minX: -0.4,
                        maxX: _spotsPeriodoActual.isEmpty ? 1 : _spotsPeriodoActual.length.toDouble() - 0.6,
                        lineTouchData: LineTouchData(
                          touchSpotThreshold: 35, 
                          touchTooltipData: LineTouchTooltipData(
                            tooltipBgColor: isOscuro ? const Color(0xFF1E293B) : Colors.blueGrey.shade900,
                            getTooltipItems: (touchedSpots) {
                              return touchedSpots.map((spot) {
                                int idx = spot.x.toInt();
                                String etiqueta = (idx >= 0 && idx < _ejeXEtiquetasCompletas.length) 
                                    ? _ejeXEtiquetasCompletas[idx] 
                                    : "Día ${idx + 1}";
                                String periodo = spot.barIndex == 0 ? "Actual" : "Anterior";
                                return LineTooltipItem(
                                  "$etiqueta ($periodo): \$${spot.y.toStringAsFixed(0)}",
                                  const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)
                                );
                              }).toList();
                            }
                          )
                        ),
                        gridData: FlGridData(
                          show: true,
                          drawHorizontalLine: true,
                          drawVerticalLine: false,
                          getDrawingHorizontalLine: (value) => FlLine(color: isOscuro ? Colors.white10 : Colors.grey.shade100, strokeWidth: 1),
                        ),
                        borderData: FlBorderData(show: false),
                        titlesData: FlTitlesData(
                          show: true,
                          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                          leftTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: 45,
                              getTitlesWidget: (value, meta) {
                                if (value == 0) return const SizedBox.shrink();
                                return Text(
                                  value >= 1000 ? "\$${(value / 1000).toStringAsFixed(1)}K" : "\$${value.toStringAsFixed(0)}",
                                  style: TextStyle(color: isOscuro ? Colors.white38 : Colors.grey.shade500, fontSize: 9, fontWeight: FontWeight.bold),
                                  textAlign: TextAlign.right,
                                );
                              },
                            )
                          ),
                          bottomTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: 45, 
                              interval: 1, 
                              getTitlesWidget: (value, meta) {
                                // 🔥 SOLUCIÓN DEFINITIVA A LÍNEAS DUPLICADAS: Se filtran valores decimales/fraccionarios del eje
                                double resto = value - value.roundToDouble();
                                if (resto.abs() > 0.01) return const SizedBox.shrink();

                                int idx = value.round();
                                if (idx < 0 || idx >= _ejeXEtiquetas.length || _ejeXEtiquetas[idx].isEmpty) {
                                  return const SizedBox.shrink();
                                }
                                return SideTitleWidget(
                                  axisSide: meta.axisSide,
                                  angle: -1.5708, // Rotación de -90 grados
                                  space: 8,
                                  // 🔥 CORREGIDO: Desplazamiento corrector para alinear el texto bajo el punto vertical exacto
                                  child: Transform.translate(
                                    offset: const Offset(-3, 0), 
                                    child: Text(
                                      _ejeXEtiquetas[idx],
                                      style: TextStyle(
                                        color: isOscuro ? Colors.white38 : Colors.grey.shade500, 
                                        fontSize: 8, 
                                        fontWeight: FontWeight.bold
                                      ),
                                    ),
                                  ),
                                );
                              },
                            )
                          )
                        ),
                        lineBarsData: [
                          LineChartBarData(
                            spots: _spotsPeriodoActual.isEmpty ? [const FlSpot(0, 0)] : _spotsPeriodoActual,
                            isCurved: true,
                            color: Colors.blueAccent,
                            barWidth: 3.5,
                            isStrokeCapRound: true,
                            dotData: const FlDotData(show: false),
                            belowBarData: BarAreaData(
                              show: true,
                              color: Colors.blueAccent.withOpacity(isOscuro ? 0.08 : 0.05),
                            ),
                          ),
                          LineChartBarData(
                            spots: _spotsPeriodoPrevio.isEmpty ? [const FlSpot(0, 0)] : _spotsPeriodoPrevio,
                            isCurved: true,
                            color: Colors.blue.withOpacity(0.4),
                            barWidth: 2,
                            dashArray: [6, 4],
                            isStrokeCapRound: true,
                            dotData: const FlDotData(show: false),
                            belowBarData: BarAreaData(show: false),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 25),

          // 3. VOLUMEN DE PEDIDOS (Con filtro independiente)
          _tituloConFiltro(
            "Volumen de Pedidos (#)", 
            Icons.assessment, 
            _filtroPedidos, 
            isOscuro,
            (v) {
              if (v != null) {
                setState(() { _filtroPedidos = v; }); 
                _cargarDatosGraficos();
              }
            }
          ),
          Card(
            color: isOscuro ? Theme.of(context).cardColor : Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            elevation: isOscuro ? 0 : 2,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 20, 10, 15),
              child: SizedBox(
                height: 200,
                child: BarChart(
                  BarChartData(
                    alignment: BarChartAlignment.spaceAround,
                    maxY: _maxYPedidosGrafico,
                    barTouchData: BarTouchData(
                      touchTooltipData: BarTouchTooltipData(
                        tooltipBgColor: isOscuro ? const Color(0xFF1E293B) : Colors.blueGrey.shade900,
                        getTooltipItem: (group, groupIndex, rod, rodIndex) {
                          int idx = group.x.toInt();
                          // 🔥 CORREGIDO: Muestra las fechas detalladas en las columnas de pedidos
                          String etiqueta = (idx >= 0 && idx < _ejeXPedidosEtiquetasCompletas.length)
                              ? _ejeXPedidosEtiquetasCompletas[idx]
                              : "Día ${idx + 1}";
                          return BarTooltipItem(
                            "$etiqueta: ${rod.toY.toStringAsFixed(0)} ${rod.toY.toInt() == 1 ? 'pedido' : 'pedidos'}",
                            const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)
                          );
                        }
                      )
                    ),
                    titlesData: FlTitlesData(
                      show: true,
                      topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 30,
                          getTitlesWidget: (value, meta) {
                            return Text(
                              value.toStringAsFixed(0),
                              style: TextStyle(color: isOscuro ? Colors.white38 : Colors.grey.shade500, fontSize: 9, fontWeight: FontWeight.bold),
                            );
                          },
                        )
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 45, // Espacio ampliado para rotación
                          interval: 1,
                          getTitlesWidget: (value, meta) {
                            // 🔥 EVITA DUPLICADOS EN LOS BORDES DE LAS BARRAS
                            double resto = value - value.roundToDouble();
                            if (resto.abs() > 0.01) return const SizedBox.shrink();

                            int idx = value.round();
                            if (idx < 0 || idx >= _ejeXPedidosEtiquetas.length || _ejeXPedidosEtiquetas[idx].isEmpty) {
                              return const SizedBox.shrink();
                            }
                            return SideTitleWidget(
                              axisSide: meta.axisSide,
                              angle: -1.5708, // 🔥 CORREGIDO: Rotación vertical aplicada
                              space: 8,
                              // 🔥 CORREGIDO: Desplazamiento corrector para alinear el texto de barras
                              child: Transform.translate(
                                offset: const Offset(-3, 0), 
                                child: Text(
                                  _ejeXPedidosEtiquetas[idx],
                                  style: TextStyle(
                                    color: isOscuro ? Colors.white38 : Colors.grey.shade500, 
                                    fontSize: 8, 
                                    fontWeight: FontWeight.bold
                                  ),
                                ),
                              ),
                            );
                          },
                        )
                      )
                    ),
                    borderData: FlBorderData(show: false),
                    gridData: const FlGridData(show: false),
                    barGroups: _barGroupsPedidos,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 25),

          // PANEL CONTROLES PARA RANKINGS (Límite y Tipo)
          _tituloSeccion("Configuración de Rankings", Icons.settings, isOscuro),
          Card(
            color: isOscuro ? Theme.of(context).cardColor : Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // Filtro Período
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("Periodo", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey)),
                      DropdownButton<String>(
                        value: _filtroRankings,
                        dropdownColor: isOscuro ? const Color(0xFF0F172A) : Colors.white,
                        style: TextStyle(color: isOscuro ? Colors.cyanAccent : Colors.blue.shade800, fontWeight: FontWeight.bold, fontSize: 12),
                        items: ['Semana', 'Mes', 'Año'].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                        onChanged: (v) {
                          if (v != null) {
                            setState(() { _filtroRankings = v; });
                            _cargarDatosGraficos();
                          }
                        },
                      ),
                    ],
                  ),
                  // Filtro Tipo (Productos vs Variantes)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("Agrupar por", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey)),
                      DropdownButton<String>(
                        value: _tipoRanking,
                        dropdownColor: isOscuro ? const Color(0xFF0F172A) : Colors.white,
                        style: TextStyle(color: isOscuro ? Colors.cyanAccent : Colors.blue.shade800, fontWeight: FontWeight.bold, fontSize: 12),
                        items: ['Productos', 'Variantes'].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
                        onChanged: (v) {
                          if (v != null) {
                            setState(() { _tipoRanking = v; });
                            _cargarDatosGraficos();
                          }
                        },
                      ),
                    ],
                  ),
                  // Filtro Límitación
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("Mostrar", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey)),
                      DropdownButton<int>(
                        value: _limiteRankings,
                        dropdownColor: isOscuro ? const Color(0xFF0F172A) : Colors.white,
                        style: TextStyle(color: isOscuro ? Colors.cyanAccent : Colors.blue.shade800, fontWeight: FontWeight.bold, fontSize: 12),
                        items: [5, 10, 20].map((e) => DropdownMenuItem(value: e, child: Text("Top $e"))).toList(),
                        onChanged: (v) {
                          if (v != null) {
                            setState(() { _limiteRankings = v; });
                            _cargarDatosGraficos();
                          }
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 15),

          // 4. TOP 5 PRODUCTOS MÁS VENDIDOS
          _tituloSeccion("Top $_limiteRankings ${_tipoRanking == 'Productos' ? 'Productos' : 'Variantes'} más Vendidos", Icons.star_border, isOscuro),
          _listaRankingsProductos(_topProductos, isOscuro),
          const SizedBox(height: 25),

          // 5. TOP 5 MEJORES CLIENTES
          _tituloSeccion("Top $_limiteRankings mejores Clientes", Icons.people_outline, isOscuro),
          _listaRankingsClientes(_topClientes, isOscuro),
          const SizedBox(height: 25),

          // 6. RETENCIÓN DE CLIENTES (Panel 15, 30 y 60 días - Scroll para evitar overflow)
          _tituloSeccion("Retención de Clientes (Toca para ver nombres)", Icons.pie_chart, isOscuro),
          Card(
            color: isOscuro ? Theme.of(context).cardColor : Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            elevation: isOscuro ? 0 : 2,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal, 
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _columnaRetencionInteractiva("15 días", _retencionClientes['15']?['activos'] ?? 0, _retencionClientes['15']?['inactivos'] ?? 0, 15, isOscuro),
                  Container(width: 1, height: 110, margin: const EdgeInsets.symmetric(horizontal: 14), color: isOscuro ? Colors.white10 : Colors.grey.shade200),
                  _columnaRetencionInteractiva("30 días", _retencionClientes['30']?['activos'] ?? 0, _retencionClientes['30']?['inactivos'] ?? 0, 30, isOscuro),
                  Container(width: 1, height: 110, margin: const EdgeInsets.symmetric(horizontal: 14), color: isOscuro ? Colors.white10 : Colors.grey.shade200),
                  _columnaRetencionInteractiva("60 días", _retencionClientes['60']?['activos'] ?? 0, _retencionClientes['60']?['inactivos'] ?? 0, 60, isOscuro),
                ],
              ),
            ),
          ),
          const SizedBox(height: 25),

          // 7. INVENTARIO ESTANCADO
          _tituloConFiltroDias(
            "Inventario Estancado (+$_filtroDiasEstancados días)", 
            Icons.warning_amber_rounded, 
            _filtroDiasEstancados, 
            isOscuro,
            (v) {
              if (v != null) {
                setState(() { _filtroDiasEstancados = v; });
                _cargarDatosGraficos();
              }
            },
            colorIcon: Colors.redAccent,
          ),
          Card(
            color: isOscuro ? Theme.of(context).cardColor : Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: Colors.redAccent.withOpacity(isOscuro ? 0.2 : 0.1))),
            elevation: isOscuro ? 0 : 1,
            child: _productosEstancados.isEmpty 
              ? Padding(padding: const EdgeInsets.all(22), child: Center(child: Text("¡Excelente! Todo tu inventario tiene rotación activa.", style: TextStyle(color: isOscuro ? Colors.white60 : Colors.black54, fontSize: 13))))
              : ListView.separated(
                  shrinkWrap: true, 
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _productosEstancados.length, 
                  separatorBuilder: (_,__) => Divider(height: 1, color: isOscuro ? Colors.white10 : Colors.black12),
                  itemBuilder: (ctx, i) {
                    var p = _productosEstancados[i];
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      leading: const Icon(Icons.inventory_2_outlined, color: Colors.redAccent, size: 20),
                      title: Text(p['nombre'].toString(), style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: isOscuro ? Colors.white : Colors.black87)),
                      trailing: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5), 
                        decoration: BoxDecoration(color: Colors.red.withOpacity(0.08), borderRadius: BorderRadius.circular(8)), 
                        child: Text("${p['stock']} u. en stock", style: const TextStyle(color: Colors.redAccent, fontSize: 11, fontWeight: FontWeight.w900))
                      ),
                    );
                  }
                ),
          ),
          const SizedBox(height: 50),
        ],
      ),
    );
  }

  Widget _tituloConFiltroDias(String titulo, IconData icono, int filtroActual, bool isOscuro, Function(int?) onChanged, {Color? colorIcon}) {
    return Padding(
      padding: const EdgeInsets.only(left: 5, bottom: 12, top: 15),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Row(
              children: [
                Icon(icono, size: 18, color: colorIcon ?? (isOscuro ? Colors.cyanAccent : Colors.blue.shade700)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    titulo, 
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: isOscuro ? Colors.white70 : Colors.black87), 
                    maxLines: 2, // 🔥 Corregido: Permite hasta 2 líneas para textos largos descriptivos
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: isOscuro ? Colors.white.withOpacity(0.05) : Colors.grey.shade100,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: isOscuro ? Colors.white10 : Colors.grey.shade300)
            ),
            child: DropdownButton<int>(
              value: filtroActual,
              dropdownColor: isOscuro ? const Color(0xFF0F172A) : Colors.white,
              style: TextStyle(color: isOscuro ? Colors.cyanAccent : Colors.blue.shade800, fontWeight: FontWeight.bold, fontSize: 11),
              underline: const SizedBox(),
              items: [10, 20, 30].map((e) => DropdownMenuItem<int>(value: e, child: Text("$e días", style: const TextStyle(fontSize: 11)))).toList(),
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _mostrarDetalleClientesRetencion(int dias, bool isOscuro) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator(color: Colors.cyanAccent)),
    );

    try {
      final Database db = await DBHelper.instance.database;
      final limiteFecha = DateTime.now().subtract(Duration(days: dias)).toIso8601String().substring(0, 10);

      // 1. Obtener Clientes Activos (Tienen pedidos completados en el rango)
      final activosRaw = await db.rawQuery('''
        SELECT DISTINCT c.id, COALESCE(c.nombre_completo, 'Cliente General') as nombre, c.nombre_negocio
        FROM pedidos p JOIN clientes c ON p.cliente_id = c.id
        WHERE p.estado = 'Completado' AND substr(p.fecha_hora, 1, 10) >= ?
      ''', [limiteFecha]);

      // 2. Obtener Clientes Inactivos (Registrados, pero no tienen compras en el rango)
      final inactivosRaw = await db.rawQuery('''
        SELECT id, COALESCE(nombre_completo, 'Cliente General') as nombre, nombre_negocio
        FROM clientes
        WHERE id NOT IN (
          SELECT DISTINCT cliente_id FROM pedidos WHERE estado = 'Completado' AND substr(fecha_hora, 1, 10) >= ?
        )
      ''', [limiteFecha]);

      if (mounted) Navigator.pop(context); // Cerrar indicador de carga

      if (!mounted) return;

      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (ctx) => DefaultTabController(
          length: 2,
          child: Container(
            height: MediaQuery.of(ctx).size.height * 0.65,
            decoration: BoxDecoration(
              color: isOscuro ? const Color(0xFF0F172A) : Colors.white,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(25))
            ),
            child: Column(
              children: [
                const SizedBox(height: 10),
                Container(width: 40, height: 4, decoration: BoxDecoration(color: isOscuro ? Colors.white24 : Colors.grey.shade300, borderRadius: BorderRadius.circular(2))),
                const SizedBox(height: 15),
                Text(
                  "Clientes - Periodo $dias días", 
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: isOscuro ? Colors.white : Colors.black87)
                ),
                TabBar(
                  indicatorColor: Colors.blueAccent,
                  labelColor: isOscuro ? Colors.cyanAccent : Colors.blue.shade800,
                  unselectedLabelColor: isOscuro ? Colors.white54 : Colors.grey,
                  tabs: [
                    Tab(text: "Activos (${activosRaw.length})"),
                    Tab(text: "Inactivos (${inactivosRaw.length})"),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _listaNombresBottomSheet(activosRaw, isOscuro, activos: true),
                      _listaNombresBottomSheet(inactivosRaw, isOscuro, activos: false),
                    ],
                  ),
                )
              ],
            ),
          ),
        ),
      );
    } catch (e) {
      if (mounted) Navigator.pop(context);
      debugPrint("Error cargando detalle retención: $e");
    }
  }

  Widget _listaNombresBottomSheet(List<Map<String, dynamic>> lista, bool isOscuro, {required bool activos}) {
    if (lista.isEmpty) {
      return Center(
        child: Text(
          "Sin clientes en este grupo", 
          style: TextStyle(color: isOscuro ? Colors.white38 : Colors.grey, fontSize: 12)
        )
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(15),
      itemCount: lista.length,
      separatorBuilder: (_, __) => Divider(height: 1, color: isOscuro ? Colors.white10 : Colors.black12),
      itemBuilder: (ctx, i) {
        var c = lista[i];
        String negocio = c['nombre_negocio']?.toString() ?? "";
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: CircleAvatar(
            backgroundColor: (activos ? Colors.green : Colors.redAccent).withOpacity(0.15),
            radius: 14,
            child: Icon(
              activos ? Icons.check : Icons.close, 
              color: activos ? Colors.green : Colors.redAccent, 
              size: 14
            ),
          ),
          title: Text(
            c['nombre'].toString(), 
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: isOscuro ? Colors.white : Colors.black87)
          ),
          subtitle: negocio.isNotEmpty && negocio != "null"
              ? Text(negocio, style: TextStyle(color: isOscuro ? Colors.white38 : Colors.grey, fontSize: 11))
              : null,
        );
      },
    );
  }

  // 🔥 Corregido: firma simplificada a 2 parámetros para eliminar la advertencia de forma definitiva
  Widget _indicadorLinea(Color c, String t) {
    return Row(
      children: [
        Container(
          width: 25, 
          height: 3, 
          decoration: BoxDecoration(
            color: c, 
            borderRadius: BorderRadius.circular(2),
          )
        ),
        const SizedBox(width: 8),
        Text(t, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _listaRankingsProductos(List<Map<String, dynamic>> datos, bool isOscuro) {
    return Card(
      color: isOscuro ? Theme.of(context).cardColor : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: isOscuro ? 0 : 2,
      child: datos.isEmpty 
        ? Padding(padding: const EdgeInsets.all(22), child: Center(child: Text("No hay datos en este período.", style: TextStyle(color: isOscuro ? Colors.white60 : Colors.black54, fontSize: 13))))
        : ListView.separated(
            shrinkWrap: true, 
            physics: const NeverScrollableScrollPhysics(),
            itemCount: datos.length, 
            separatorBuilder: (_,__) => Divider(height: 1, color: isOscuro ? Colors.white10 : Colors.black12),
            itemBuilder: (ctx, i) {
              var d = datos[i];
              int uVendidas = (d['total_vendido'] as num).toInt();
              int totalPeds = (d['total_pedidos'] as num).toInt();
              return ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                leading: CircleAvatar(
                  radius: 13, 
                  backgroundColor: Colors.orange.withOpacity(0.15), 
                  child: Text("${i+1}", style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Colors.orange))
                ),
                // 🔥 CORREGIDO: maxLines: 2 para que los nombres de variantes se vean completos
                title: Text(d['nombre'].toString(), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: isOscuro ? Colors.white : Colors.black87), maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text("Solicitado en $totalPeds ${totalPeds == 1 ? 'pedido' : 'pedidos'}", style: TextStyle(fontSize: 10, color: isOscuro ? Colors.white38 : Colors.grey, fontWeight: FontWeight.w500)),
                trailing: Text("$uVendidas u.", style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: Colors.orange)),
              );
            }
          ),
    );
  }

  Widget _listaRankingsClientes(List<Map<String, dynamic>> datos, bool isOscuro) {
    return Card(
      color: isOscuro ? Theme.of(context).cardColor : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: isOscuro ? 0 : 2,
      child: datos.isEmpty 
        ? Padding(padding: const EdgeInsets.all(22), child: Center(child: Text("No hay datos en este período.", style: TextStyle(color: isOscuro ? Colors.white60 : Colors.black54, fontSize: 13))))
        : ListView.separated(
            shrinkWrap: true, 
            physics: const NeverScrollableScrollPhysics(),
            itemCount: datos.length, 
            separatorBuilder: (_,__) => Divider(height: 1, color: isOscuro ? Colors.white10 : Colors.black12),
            itemBuilder: (ctx, i) {
              var d = datos[i];
              double gastado = (d['gastado'] as num).toDouble();
              int totalPeds = (d['total_pedidos'] as num).toInt();
              return ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                leading: CircleAvatar(
                  radius: 13, 
                  backgroundColor: Colors.green.withOpacity(0.15), 
                  child: Text("${i+1}", style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Colors.green))
                ),
                // 🔥 CORREGIDO: maxLines: 2 para evitar truncamientos
                title: Text(d['nombre'].toString(), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: isOscuro ? Colors.white : Colors.black87), maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text("Registró $totalPeds ${totalPeds == 1 ? 'pedido' : 'pedidos'}", style: TextStyle(fontSize: 10, color: isOscuro ? Colors.white38 : Colors.grey, fontWeight: FontWeight.w500)),
                trailing: Text("\$${gastado.toStringAsFixed(0)}", style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: Colors.green)),
              );
            }
          ),
    );
  }
  Widget _tituloSeccion(String texto, IconData icono, bool isOscuro, {Color? colorIcon}) {
    return Padding(
      padding: const EdgeInsets.only(left: 5, bottom: 12, top: 5),
      child: Row(
        children: [
          Icon(icono, size: 18, color: colorIcon ?? (isOscuro ? Colors.cyanAccent : Colors.blue.shade700)),
          const SizedBox(width: 8),
          // 🔥 CORREGIDO: Expanded para evitar que los textos largos desborden la pantalla
          Expanded(
            child: Text(texto, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: isOscuro ? Colors.white70 : Colors.black87)),
          ),
        ],
      ),
    );
  }

  Widget _tituloConFiltro(String titulo, IconData icono, String filtroActual, bool isOscuro, Function(String?) onChanged) {
    return Padding(
      padding: const EdgeInsets.only(left: 5, bottom: 12, top: 15),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // 🔥 CORREGIDO: Expanded para que el título y el icono se adapten al espacio sobrante
          Expanded(
            child: Row(
              children: [
                Icon(icono, size: 18, color: isOscuro ? Colors.cyanAccent : Colors.blue.shade700),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(titulo, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: isOscuro ? Colors.white70 : Colors.black87), maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: isOscuro ? Colors.white.withOpacity(0.05) : Colors.grey.shade100,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: isOscuro ? Colors.white10 : Colors.grey.shade300)
            ),
            child: DropdownButton<String>(
              value: filtroActual,
              dropdownColor: isOscuro ? const Color(0xFF0F172A) : Colors.white,
              style: TextStyle(color: isOscuro ? Colors.cyanAccent : Colors.blue.shade800, fontWeight: FontWeight.bold, fontSize: 11),
              underline: const SizedBox(),
              items: ['Semana', 'Mes', 'Año'].map((e) => DropdownMenuItem(value: e, child: Text(e, style: const TextStyle(fontSize: 11)))).toList(),
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _columnaRetencionInteractiva(String titulo, int activos, int inactivos, int diasRango, bool isOscuro) {
    int total = activos + inactivos;
    double porcentaje = total > 0 ? (activos / total) * 100 : 0.0;
    return InkWell(
      onTap: () => _mostrarDetalleClientesRetencion(diasRango, isOscuro),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          children: [
            Text(titulo, style: TextStyle(fontWeight: FontWeight.w900, fontSize: 11, color: isOscuro ? Colors.white60 : Colors.black54)),
            const SizedBox(height: 12),
            Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  height: 55,
                  width: 55,
                  child: CircularProgressIndicator(
                    value: total > 0 ? activos / total : 0.0,
                    backgroundColor: isOscuro ? Colors.white.withOpacity(0.05) : Colors.grey.shade100,
                    color: porcentaje >= 50 ? Colors.green : Colors.redAccent,
                    strokeWidth: 5.5,
                  ),
                ),
                Text(
                  "${porcentaje.toStringAsFixed(0)}%", 
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 11, color: isOscuro ? Colors.white : Colors.black87)
                ),
              ],
            ),
            const SizedBox(height: 12),
            // 🔥 CORREGIDO: Muestra datos puros sin etiquetas ambiguas
            Text(
              "Activos: $activos", 
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 10, color: Colors.green)
            ),
            const SizedBox(height: 2),
            Text(
              "Inactivos: $inactivos", 
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 10, color: Colors.redAccent)
            ),
          ],
        ),
      ),
    );
  }
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