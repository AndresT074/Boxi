import 'dart:typed_data';
import 'dart:convert';
import 'dart:ui' as ui; // Necesario para generar la firma automática por código
import 'package:flutter/material.dart';
import 'package:signature/signature.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../database/db_helper.dart';
import 'servicio_pdf.dart'; 
import 'pantalla_vendedores.dart'; 
import 'servicio_anuncios.dart';
import 'servicio_nube.dart';
import 'package:sqflite/sqflite.dart';

class PantallaRegistrarPedido extends StatefulWidget {
  final List<Map<String, dynamic>> carrito;
  final double totalPedido;
  
  final String? nombreWeb;
  final String? telefonoWeb;
  final Map<String, dynamic>? datosPreCargados;

  const PantallaRegistrarPedido({
    super.key, 
    required this.carrito, 
    required this.totalPedido, 
    this.nombreWeb, 
    this.telefonoWeb,
    this.datosPreCargados,
  });

  @override
  State<PantallaRegistrarPedido> createState() => _PantallaRegistrarPedidoState();
}

class _PantallaRegistrarPedidoState extends State<PantallaRegistrarPedido> {
  final _nC = TextEditingController();
  final _negC = TextEditingController();
  final _dC = TextEditingController();
  final _tC = TextEditingController();
  final _deptoC = TextEditingController();
  final _ciuC = TextEditingController();
  final _vendC = TextEditingController(); 

  int? _vId; 
  List<Map<String, dynamic>> _vendedores = [];
  List<Map<String, dynamic>> _vendedoresFiltrados = [];
  List<String> _deptosExistentes = [];
  List<String> _ciudadesExistentes = [];
  List<String> _deptosFiltrados = [];
  List<String> _ciudadesFiltradas = [];
  List<Map<String, dynamic>> _clientesExistentes = [];
  List<Map<String, dynamic>> _clientesFiltrados = [];
  
  bool _incluirLogo = true;
  bool _procesando = false; 
  bool _noNecesitaFactura = false; // Control de factura genérica

  final SignatureController _sigController = SignatureController(
    penStrokeWidth: 3, 
    penColor: Colors.black, 
    exportBackgroundColor: Colors.white,
  );

  @override
  void initState() { 
    super.initState(); 
    _cargarDatos(); 
  }

  @override
  void dispose() { 
    _sigController.dispose(); 
    _nC.dispose(); _negC.dispose(); _dC.dispose(); _tC.dispose(); 
    _deptoC.dispose(); _ciuC.dispose(); _vendC.dispose();
    super.dispose(); 
  }

  Future<void> _cargarDatos() async {
    final db = await DBHelper.instance.database;
    final v = await db.query('vendedores');
    final c = await db.query('clientes');
    
    final dRaw = await db.rawQuery('SELECT DISTINCT departamento FROM clientes WHERE departamento IS NOT NULL AND departamento != ""');
    final cRaw = await db.rawQuery('SELECT DISTINCT ciudad FROM clientes WHERE ciudad IS NOT NULL AND ciudad != ""');

    if (!mounted) return;
    setState(() { 
      _vendedores = v; 
      _clientesExistentes = c; 
      _deptosExistentes = dRaw.map((e) => e['departamento'].toString()).toList();
      _ciudadesExistentes = cRaw.map((e) => e['ciudad'].toString()).toList();
    });

    if (widget.datosPreCargados != null) {
      final d = widget.datosPreCargados!;
      _nC.text = d['nombre']?.toString() ?? "";
      _negC.text = d['negocio']?.toString() ?? "";
      _dC.text = d['direccion']?.toString() ?? "";
      _tC.text = d['telefono']?.toString() ?? "";
      _ciuC.text = d['ciudad']?.toString() ?? "";
      _deptoC.text = d['departamento']?.toString() ?? ""; 
    } else {
      if (widget.nombreWeb != null) _nC.text = widget.nombreWeb!;
      if (widget.telefonoWeb != null) _tC.text = widget.telefonoWeb!;
    }
  }
  
  void _filtrarClientes(String query) {
    setState(() {
      if (query.isEmpty) { _clientesFiltrados = []; } 
      else {
        _clientesFiltrados = _clientesExistentes.where((c) => 
          c['nombre_completo'].toString().toLowerCase().contains(query.toLowerCase()) ||
          (c['nombre_negocio'] ?? '').toString().toLowerCase().contains(query.toLowerCase())
        ).toList();
      }
    });
  }

  void _seleccionarCliente(Map<String, dynamic> c) {
    setState(() {
      _nC.text = c['nombre_completo'] ?? ''; 
      _negC.text = c['nombre_negocio'] ?? '';
      _dC.text = c['direccion'] ?? ''; 
      _tC.text = c['telefono'] ?? '';
      _deptoC.text = c['departamento'] ?? ''; 
      _ciuC.text = c['ciudad'] ?? '';
      _clientesFiltrados = [];
    });
  }

  void _filtrarVendedores(String query) {
    _vId = null; 
    setState(() {
      if (query.isEmpty) { _vendedoresFiltrados = []; } 
      else {
        _vendedoresFiltrados = _vendedores.where((v) => 
          v['nombre'].toString().toLowerCase().contains(query.toLowerCase())
        ).toList();
      }
    });
  }

  void _seleccionarVendedor(Map<String, dynamic> v) {
    setState(() {
      _vId = v['id'] as int;
      _vendC.text = v['nombre'];
      _vendedoresFiltrados = [];
    });
  }

  void _filtrarDeptos(String query) {
    setState(() {
      _deptosFiltrados = query.isEmpty 
          ? [] 
          : _deptosExistentes.where((d) => d.toLowerCase().contains(query.toLowerCase())).toList();
    });
  }

  void _filtrarCiudades(String query) {
    setState(() {
      _ciudadesFiltradas = query.isEmpty 
          ? [] 
          : _ciudadesExistentes.where((c) => c.toLowerCase().contains(query.toLowerCase())).toList();
    });
  }

  void _mostrarError(String mensaje) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(children:[const Icon(Icons.error_outline, color: Colors.white), const SizedBox(width: 10), Expanded(child: Text(mensaje, style: const TextStyle(fontWeight: FontWeight.bold)))]),
        backgroundColor: Colors.red.shade800,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(15),
        duration: const Duration(seconds: 4),
      )
    );
  }

  // 🔥 Genera un PNG de una línea recta automáticamente para "No necesita factura"
  Future<Uint8List> _generarFirmaLinea() async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromPoints(const Offset(0, 0), const Offset(300, 150)));
    final paint = Paint()
      ..color = Colors.black
      ..strokeWidth = 4
      ..strokeCap = ui.StrokeCap.round;
    canvas.drawLine(const Offset(30, 75), const Offset(270, 75), paint);
    final picture = recorder.endRecording();
    final img = await picture.toImage(300, 150);
    final pngBytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return pngBytes!.buffer.asUint8List();
  }

  Future<void> _guardarTodo() async {
    if (_procesando) return;

    // 1. VALIDACIONES INICIALES
    if (_nC.text.trim().isEmpty) return _mostrarError("El Nombre del Cliente es obligatorio.");
    if (_tC.text.trim().isEmpty) return _mostrarError("El Teléfono celular es obligatorio.");
    if (_deptoC.text.trim().isEmpty) return _mostrarError("El Departamento es obligatorio.");
    if (_ciuC.text.trim().isEmpty) return _mostrarError("La Ciudad o Municipio es obligatoria.");
    if (_vendC.text.trim().isEmpty || _vId == null) return _mostrarError("Debe seleccionar un Vendedor.");
    
    // Si no necesita factura, nos saltamos la validación física de la firma
    if (!_noNecesitaFactura && _sigController.isEmpty) {
      return _mostrarError("La Firma del Cliente es obligatoria.");
    }

    setState(() => _procesando = true);

    try {
      final db = await DBHelper.instance.database;
      final prefs = await SharedPreferences.getInstance();
      bool esPremium = prefs.getBool('es_premium') ?? false;

      // 2. PREPARAR FECHA Y FIRMA (Física o generada)
      final DateTime ahora = DateTime.now();
      final String periodo = ahora.hour >= 12 ? 'PM' : 'AM';
      final int hora12 = ahora.hour > 12 ? ahora.hour - 12 : (ahora.hour == 0 ? 12 : ahora.hour);
      final String fechaFormateada = "${ahora.year}-${ahora.month.toString().padLeft(2, '0')}-${ahora.day.toString().padLeft(2, '0')} $hora12:${ahora.minute.toString().padLeft(2, '0')} $periodo";
      
      final Uint8List? firmaBytes = _noNecesitaFactura 
          ? await _generarFirmaLinea() 
          : await _sigController.toPngBytes();

      // 3. GESTIONAR CLIENTE (LOCAL)
      int clienteId;
      Map<String, dynamic> clienteData = {
        'nombre_completo': _nC.text.trim(), 
        'nombre_negocio': _negC.text.trim(), 
        'direccion': _dC.text.trim(), 
        'telefono': _tC.text.trim(), 
        'departamento': _deptoC.text.trim(), 
        'ciudad': _ciuC.text.trim()
      };
      
      final existeCliente = _clientesExistentes.where((c) => c['nombre_completo'].toString().toLowerCase() == _nC.text.trim().toLowerCase()).toList();
      if (existeCliente.isNotEmpty) {
        clienteId = existeCliente.first['id'] as int;
        clienteData['id'] = clienteId;
        await db.update('clientes', clienteData, where: 'id = ?', whereArgs:[clienteId]);
      } else {
        clienteId = await db.insert('clientes', clienteData);
        clienteData['id'] = clienteId;
      }

      // 4. SEPARAR DOMICILIO Y PRODUCTOS
      double valorDomicilio = 0;
      List<Map<String, dynamic>> productosReales = [];
      for (var item in widget.carrito) {
        if (item['es_domicilio'] == true) {
          valorDomicilio = (item['precio_venta'] as num).toDouble();
        } else {
          productosReales.add(item);
        }
      }

      // 5. PROCESAR PRODUCTOS Y STOCK (LOCAL)
      double gananciaPedido = 0;
      List<Map<String, dynamic>> prodsParaNube = []; 

      for (var item in productosReales) {
        final pResult = await db.query('productos', where: 'id = ?', whereArgs: [item['id']]);
        if (pResult.isNotEmpty) {
          var p = pResult.first;
          double pCompra = (p['precio_compra'] as num).toDouble();
          double pVentaBase = (item['precio_venta'] as num).toDouble();
          double descPct = (item['descuento'] ?? 0).toDouble();
          double pVentaFinal = pVentaBase - (pVentaBase * (descPct / 100));

          int cant = item['cantidad'] as int;
          gananciaPedido += (pVentaFinal - pCompra) * cant;

          int nuevoStockGlobal = (p['stock'] as int) - cant;
          String variantesStr = p['variantes']?.toString() ?? "";

          if (item['es_variante'] == true && item['g_index'] != null && item['o_index'] != null) {
            try {
              List<dynamic> grupos = jsonDecode(variantesStr);
              int gIdx = item['g_index'] as int;
              int oIdx = item['o_index'] as int;
              grupos[gIdx]['opciones'][oIdx]['stock'] -= cant;
              
              int totalPositivos = 0;
              for (var g in grupos) {
                for (var o in g['opciones']) { if ((o['stock'] as int) > 0) totalPositivos += (o['stock'] as int); }
              }
              nuevoStockGlobal = totalPositivos;
              variantesStr = jsonEncode(grupos);
            } catch(e) { debugPrint("Error stock variante: $e"); }
          }

          await db.update('productos', {'stock': nuevoStockGlobal, 'variantes': variantesStr}, where: 'id = ?', whereArgs: [item['id']]);

          if (esPremium) {
            var pClon = Map<String, dynamic>.from(p);
            pClon['stock'] = nuevoStockGlobal;
            pClon['variantes'] = variantesStr;
            prodsParaNube.add(pClon);
          }
        }
      }

      // 6. GUARDAR PEDIDO (LOCAL)
      Map<String, dynamic> pedidoData = {
        'fecha_hora': fechaFormateada,
        'cliente_id': clienteId, 
        'vendedor_id': _vId, 
        'total_venta': widget.totalPedido, 
        'ganancia_total': gananciaPedido, 
        'estado': 'Pendiente', 
        'departamento': _deptoC.text.trim(), 
        'ciudad': _ciuC.text.trim(), 
        'firma': firmaBytes,
        'valor_domicilio': valorDomicilio,
        'cliente_nombre_snapshot': _nC.text.trim(), 
      };
      int pedidoId = await db.insert('pedidos', pedidoData);
      pedidoData['id'] = pedidoId;

      // 7. GUARDAR DETALLES CON IDs BLINDADOS (ANTI-DUPLICADOS)
      List<Map<String, dynamic>> listaDetalles = [];
      int offsetIndex = 0;
      
      for (var item in productosReales) {
        double pVentaBase = (item['precio_venta'] as num).toDouble();
        double descPct = (item['descuento'] ?? 0).toDouble();
        double precioFinal = pVentaBase - (pVentaBase * (descPct / 100));

        int detIdUnico = DateTime.now().millisecondsSinceEpoch + offsetIndex;
        offsetIndex++;

        Map<String, dynamic> det = {
          'id': detIdUnico,
          'pedido_id': pedidoId, 
          'producto_id': item['id'], 
          'cantidad': item['cantidad'], 
          'precio_unitario': pVentaBase, 
          'subtotal': precioFinal * (item['cantidad'] as int),
          'nombre_snapshot': (item['nombre'] ?? 'PRODUCTO').toString(),
          'descuento': descPct 
        };
        
        await db.insert('detalle_pedidos', det, conflictAlgorithm: ConflictAlgorithm.replace);
        listaDetalles.add(det);
      }

      // 8. SINCRONIZACIÓN NUBE 
      if (esPremium) {
        final vend = _vendedores.firstWhere((v) => v['id'] == _vId, orElse: () => {});
        
        ServicioNube.guardarVentaCompletaBatch(
          cliente: clienteData,
          pedido: pedidoData,
          detalles: listaDetalles,
          productos: prodsParaNube, 
          vendedor: vend,
        ).catchError((error) {
          debugPrint("Error subiendo a la nube en segundo plano: $error");
        });
      }

      if (mounted) {
        setState(() => _procesando = false);
        _mostrarDialogoExito(pedidoId);
      }

    } catch (e) {
      if (mounted) setState(() => _procesando = false);
      _mostrarError("Ocurrió un error inesperado: $e");
    }
  }

  void _mostrarDialogoExito(int pedidoId) async {
    final prefs = await SharedPreferences.getInstance();
    bool esPremium = prefs.getBool('es_premium') ?? false;
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;

    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return Dialog(
            backgroundColor: Theme.of(context).cardColor,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: isOscuro ? Colors.white10 : Colors.transparent),
            ),
            child: Container(
              padding: const EdgeInsets.all(25),
              constraints: const BoxConstraints(maxWidth: 400),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children:[
                    const Icon(Icons.check_circle, color: Colors.green, size: 80),
                    const SizedBox(height: 15),
                    Text(
                      '¡VENTA EXITOSA!', 
                      style: TextStyle(
                        fontSize: 20, 
                        fontWeight: FontWeight.bold, 
                        color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1)
                      )
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'El pedido ha sido registrado correctamente.', 
                      textAlign: TextAlign.center, 
                      style: TextStyle(color: isOscuro ? Colors.white60 : Colors.grey)
                    ),
                    const SizedBox(height: 25),
                    
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isOscuro ? Colors.greenAccent.shade700 : Colors.green.shade800, 
                        foregroundColor: Colors.white, 
                        minimumSize: const Size(double.infinity, 55), 
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))
                      ),
                      // 🔥 CAMBIADO: Icono de compartir para mayor claridad estética
                      icon: const Icon(Icons.share_rounded),
                      label: const Text('COMPARTIR FACTURA PDF', style: TextStyle(fontWeight: FontWeight.bold)),
                      onPressed: () async {
                        final nombreNeg = prefs.getString('nombre_negocio') ?? "Mi Negocio";
                        final logo = (esPremium && _incluirLogo) ? prefs.getString('logo_path') : null;
                        final db = await DBHelper.instance.database;
                        
                        final pRaw = await db.rawQuery('''
                          SELECT pedidos.*, clientes.nombre_completo as cliente_nombre, clientes.nombre_negocio as negocio_nombre, 
                          clientes.direccion as cliente_direccion, clientes.ciudad as cliente_ciudad,           
                          vendedores.telefono as vendedor_telefono, vendedores.nombre as vendedor_nombre 
                          FROM pedidos JOIN clientes ON pedidos.cliente_id = clientes.id
                          JOIN vendedores ON pedidos.vendedor_id = vendedores.id WHERE pedidos.id = $pedidoId
                        ''');
                        final d = await db.query('detalle_pedidos', where: 'pedido_id = ?', whereArgs: [pedidoId]);
                        List<Map<String, dynamic>> dets = d.map((item) => Map<String, dynamic>.from(item)).toList();
                        
                        // 🔥 CAMBIADO: Ahora llama a compartirFactura() para abrir apps recomendadas (WhatsApp, Gmail, etc.)
                        await ServicioPdf.compartirFactura(pedido: pRaw.first, detalles: dets, nombreNegocio: nombreNeg, logoPath: logo);
                      },
                    ),
                    
                    const SizedBox(height: 15),
                    
                    if (esPremium)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          color: isOscuro ? Colors.white.withOpacity(0.05) : Colors.blue.shade50, 
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: isOscuro ? Colors.white10 : Colors.transparent)
                        ),
                        child: CheckboxListTile(
                          title: Text(
                            "Incluir logo en PDF", 
                            style: TextStyle(
                              fontSize: 14, 
                              fontWeight: FontWeight.w600, 
                              color: isOscuro ? Colors.white70 : Colors.black87
                            )
                          ),
                          value: _incluirLogo, 
                          activeColor: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1),
                          onChanged: (val) => setDialogState(() => _incluirLogo = val!),
                          controlAffinity: ListTileControlAffinity.leading, 
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    
                    const SizedBox(height: 25),
                    const Divider(),
                    const SizedBox(height: 10),
                    
                    SizedBox(
                      width: double.infinity,
                      child: TextButton(
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 15), 
                          backgroundColor: isOscuro ? Colors.white.withOpacity(0.1) : Colors.grey.shade200, 
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))
                        ),
                        onPressed: () {
                          Navigator.pop(ctx); 
                          Navigator.pop(context, true); 
                          if (!esPremium) {
                            Future.delayed(const Duration(milliseconds: 300), () {
                              ServicioAnuncios.mostrarAnuncioIntersticial(() {});
                            });
                          }
                        },
                        child: Text(
                          'FINALIZAR Y VOLVER', 
                          style: TextStyle(color: isOscuro ? Colors.white : Colors.black87, fontWeight: FontWeight.bold)
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    bool esHorizontal = MediaQuery.of(context).orientation == Orientation.landscape;
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: const Text('Registrar Venta'), backgroundColor: isOscuro ? const Color(0xFF0D1B2A) : const Color(0xFF0D47A1)),
      body: Stack(
        children:[
          SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                // SECCIÓN SUPERIOR: CASILLA "NO NECESITA FACTURA"
                Container(
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: _noNecesitaFactura 
                        ? (isOscuro ? Colors.orange.withOpacity(0.08) : Colors.orange.shade50) 
                        : (isOscuro ? Colors.white.withOpacity(0.03) : Colors.grey.shade50),
                    borderRadius: BorderRadius.circular(15),
                    border: Border.all(
                      color: _noNecesitaFactura 
                          ? Colors.orange 
                          : (isOscuro ? Colors.white12 : Colors.grey.shade300),
                      width: 1.5,
                    ),
                  ),
                  child: SwitchListTile(
                    title: const Text(
                      "NO NECESITA FACTURA / REMISIÓN", 
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 0.5)
                    ),
                    subtitle: const Text(
                      "Autocompleta con datos genéricos y aplica firma automática de línea.", 
                      style: TextStyle(fontSize: 11)
                    ),
                    activeColor: Colors.orange,
                    value: _noNecesitaFactura,
                    onChanged: (val) {
                      setState(() {
                        _noNecesitaFactura = val;
                        if (val) {
                          _nC.text = "Cliente Final";
                          _negC.text = "Sin negocio";
                          _dC.text = "Sin dirección";
                          _tC.text = "0000000000";
                          _deptoC.text = "General";
                          _ciuC.text = "General";
                          _sigController.clear(); 
                        } else {
                          _nC.clear();
                          _negC.clear();
                          _dC.clear();
                          _tC.clear();
                          _deptoC.clear();
                          _ciuC.clear();
                        }
                      });
                    },
                  ),
                ),
                
                // Formulario Principal
                esHorizontal 
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children:[
                          Expanded(child: _buildColumnaIzquierda(esHorizontal)),
                          const SizedBox(width: 20),
                          Expanded(child: _buildColumnaDerecha(esHorizontal)),
                        ],
                      )
                    : Column(
                        children:[
                          _buildColumnaIzquierda(esHorizontal),
                          const SizedBox(height: 15),
                          _buildColumnaDerecha(esHorizontal),
                        ],
                      ),
              ],
            ),
          ),
          
          if (_procesando)
            Container(
              color: Colors.black.withOpacity(0.4),
              child: const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            )
        ],
      ),
    );
  }

  Widget _buildColumnaIzquierda(bool esHorizontal) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children:[
        _inBuscador(_nC, 'Nombre Cliente', Icons.person, _filtrarClientes),
        _construirListaSugerencias(
          _clientesFiltrados, 
          (c) => _seleccionarCliente(c),
          (c) => c['nombre_completo'],
          (c) => c['nombre_negocio'] ?? ''
        ),
        const SizedBox(height: 12),
        _in(_negC, 'Nombre del Negocio (Opcional)', Icons.store),
        const SizedBox(height: 12),
        _in(_dC, 'Dirección (Opcional)', Icons.location_on), 
        const SizedBox(height: 12),
        _in(_tC, 'Teléfono Celular', Icons.phone, keyboard: TextInputType.number),
        if (esHorizontal) ...[
          const SizedBox(height: 20),
          _buildFirma(esHorizontal),
        ]
      ],
    );
  }

  Widget _buildColumnaDerecha(bool esHorizontal) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children:[
        _inBuscador(_deptoC, 'Departamento', Icons.map, _filtrarDeptos),
        if (_deptosFiltrados.isNotEmpty)
          _sugerenciasSimples(_deptosFiltrados, (val) {
            _deptoC.text = val;
            setState(() => _deptosFiltrados = []);
          }),
        const SizedBox(height: 15),
        _inBuscador(_ciuC, 'Ciudad o Municipio', Icons.location_city, _filtrarCiudades),
        if (_ciudadesFiltradas.isNotEmpty)
          _sugerenciasSimples(_ciudadesFiltradas, (val) {
            _ciuC.text = val;
            setState(() => _ciudadesFiltradas = []);
          }),
        const SizedBox(height: 15),
        _inBuscador(_vendC, 'Vendedor Responsable', Icons.badge, _filtrarVendedores),
        if (_vendC.text.isNotEmpty && _vId == null)
          Card(
            elevation: 4,
            margin: const EdgeInsets.only(top: 4, bottom: 10),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: const BorderSide(color: Colors.blueAccent)),
            child: _vendedoresFiltrados.isEmpty 
              ? ListTile(
                  leading: const Icon(Icons.person_add, color: Colors.blue),
                  title: const Text('Registrar nuevo vendedor', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.blue)),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PantallaVendedores())).then((_) => _cargarDatos()),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _vendedoresFiltrados.length,
                  itemBuilder: (ctx, i) => ListTile(
                    title: Text(_vendedoresFiltrados[i]['nombre']),
                    onTap: () => _seleccionarVendedor(_vendedoresFiltrados[i]),
                  )
                )
          ),
        const SizedBox(height: 20),
        if (!esHorizontal) ...[
          _buildFirma(esHorizontal),
          const SizedBox(height: 20),
        ],
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF0D47A1), foregroundColor: Colors.white, minimumSize: const Size(double.infinity, 60), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))), 
          onPressed: _procesando ? null : _guardarTodo, 
          child: const Text('CONFIRMAR VENTA', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16))
        ),
      ]
    );
  }

  Widget _sugerenciasSimples(List<String> lista, Function(String) onTap) {
    return Card(
      elevation: 2,
      child: Column(
        children: lista.map((s) => ListTile(
          title: Text(s),
          onTap: () => onTap(s),
          dense: true,
        )).toList(),
      ),
    );
  }

  Widget _buildFirma(bool esHorizontal) {
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children:[
        Text(
          "Firma del Cliente:", 
          style: TextStyle(
            fontWeight: FontWeight.bold, 
            fontSize: 16, 
            color: isOscuro ? Colors.white70 : Colors.black
          )
        ),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: isOscuro ? Colors.black : Colors.white,
            border: Border.all(
              color: isOscuro ? Colors.white10 : Colors.grey.shade400, 
              width: 2
            ), 
            borderRadius: BorderRadius.circular(15),
            boxShadow: isOscuro ? [] : [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10)]
          ), 
          child: ClipRRect(
            borderRadius: BorderRadius.circular(13),
            child: _noNecesitaFactura 
                ? Container(
                    height: esHorizontal ? 150 : 160,
                    width: double.infinity,
                    color: isOscuro ? Colors.white.withOpacity(0.05) : Colors.grey[50],
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.draw_rounded, color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1), size: 30),
                          const SizedBox(height: 8),
                          Text(
                            "Firma Automática Activa (Línea)", 
                            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: isOscuro ? Colors.white70 : Colors.black54)
                          ),
                        ],
                      ),
                    ),
                  )
                : Signature(
                    controller: _sigController, 
                    height: esHorizontal ? 150 : 160, 
                    width: double.infinity, 
                    backgroundColor: isOscuro ? const Color.fromARGB(255, 128, 125, 125) : Colors.white,
                  ),
          )
        ),
        if (!_noNecesitaFactura)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => _sigController.clear(), 
              icon: const Icon(Icons.refresh, color: Colors.redAccent, size: 18), 
              label: const Text("Limpiar Firma", style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold))
            ),
          )
      ],
    );
  }

  Widget _in(TextEditingController c, String l, IconData i, {TextInputType keyboard = TextInputType.text}) {
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;
    return TextField(
      controller: c, 
      keyboardType: keyboard,
      style: TextStyle(color: isOscuro ? Colors.white : Colors.black), 
      decoration: InputDecoration(
        labelText: l, 
        labelStyle: TextStyle(color: isOscuro ? Colors.white60 : Colors.black54),
        prefixIcon: Icon(i, color: isOscuro ? Colors.cyanAccent : Colors.blueGrey), 
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: isOscuro ? Colors.white10 : Colors.black12)
        ),
        isDense: true
      )
    );
  }

  Widget _inBuscador(TextEditingController c, String l, IconData i, Function(String) onChanged) {
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;
    return TextField(
      controller: c, 
      onChanged: onChanged,
      style: TextStyle(color: isOscuro ? Colors.white : Colors.black),
      decoration: InputDecoration(
        labelText: l, 
        labelStyle: TextStyle(color: isOscuro ? Colors.white60 : Colors.black54),
        prefixIcon: Icon(i, color: isOscuro ? Colors.cyanAccent : Colors.blueGrey), 
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: isOscuro ? Colors.white10 : Colors.black12)
        ),
        isDense: true, 
        suffixIcon: Icon(Icons.search, color: isOscuro ? Colors.white38 : Colors.grey)
      )
    );
  }

  Widget _construirListaSugerencias(List<Map<String, dynamic>> lista, Function(Map<String, dynamic>) onTap, String Function(Map<String, dynamic>) titulo, String Function(Map<String, dynamic>) subtitulo) {
    if (lista.isEmpty) return const SizedBox.shrink();
    return Card(
      elevation: 4, margin: const EdgeInsets.only(top: 4, bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: const BorderSide(color: Colors.blueAccent)),
      child: ListView.separated(
        shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
        itemCount: lista.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (ctx, i) => ListTile(
          title: Text(titulo(lista[i]), style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text(subtitulo(lista[i])),
          onTap: () => onTap(lista[i]),
        ),
      ),
    );
  }
}