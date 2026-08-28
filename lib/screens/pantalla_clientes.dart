import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import '../database/db_helper.dart';
import 'servicio_anuncios.dart';
import 'servicio_nube.dart';
import 'pantalla_premium.dart';
import 'dart:async';

class PantallaClientes extends StatefulWidget {
  const PantallaClientes({super.key});
  @override
  State<PantallaClientes> createState() => _PantallaClientesState();
}

class _PantallaClientesState extends State<PantallaClientes> {
  StreamSubscription? _suscripcion;
  List<Map<String, dynamic>> _clientes = [];
  List<Map<String, dynamic>> _filtrados = [];
  String _nombreNegocio = "MI NEGOCIO";
  bool _esPremium = false;
  bool _buscando = false;
  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _cargar();
    _activarTiempoReal();
  }

  @override
  void dispose() {
    _suscripcion?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _activarTiempoReal() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('es_premium') ?? false) {
      _suscripcion = ServicioNube.escucharCambiosNubeRTDB(() async {
        await ServicioNube.descargarDatosPrivadosRTDB();
        if (mounted) _cargar();
      });
    }
  }

  Future<void> _cargar() async {
    final db = await DBHelper.instance.database;
    final prefs = await SharedPreferences.getInstance();

    final data = await db.rawQuery('''
      SELECT c.*, 
        (SELECT COUNT(*) FROM pedidos p WHERE p.cliente_id = c.id) AS pedidos_completos 
      FROM clientes c
      ORDER BY c.nombre_completo ASC
    ''');

    String nombreNeg = prefs.getString('nombre_negocio') ?? "MI NEGOCIO";

    if (!mounted) return;
    setState(() {
      _nombreNegocio = nombreNeg;
      _clientes = List<Map<String, dynamic>>.from(data);
      _filtrados = List<Map<String, dynamic>>.from(data);
      _esPremium = prefs.getBool('es_premium') ?? false;
    });
  }

  void _filtrar(String q) {
    setState(() {
      _filtrados = _clientes
          .where(
            (c) =>
                (c['nombre_completo'] ?? '').toString().toLowerCase().contains(
                  q.toLowerCase(),
                ) ||
                (c['telefono'] ?? '').toString().contains(q),
          )
          .toList();
    });
  }

  String _formatearTelefono(String? tel) {
    if (tel == null || tel.trim().isEmpty) return 'Sin teléfono';
    String t = tel.trim();
    if (t.startsWith('+')) return t;
    if (t.startsWith('57') && t.length == 12) {
      return '+57 ${t.substring(2)}';
    }
    if (t.length > 10 && RegExp(r'^\d+$').hasMatch(t)) {
      return '+${t.substring(0, t.length - 10)} ${t.substring(t.length - 10)}';
    }
    return t;
  }

  void _abrirFormulario({Map<String, dynamic>? cliente}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) => PantallaFormularioCliente(
          cliente: cliente,
          onGuardar: () => _cargar(),
        ),
      ),
    );
  }

  void _eliminar(int id, String nombre) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.redAccent),
            SizedBox(width: 8),
            Text(
              'Eliminar Cliente',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ],
        ),
        content: Text('¿Deseas eliminar a "$nombre"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'CANCELAR',
              style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onPressed: () async {
              final db = await DBHelper.instance.database;
              final prefs = await SharedPreferences.getInstance();

              await db.delete('clientes', where: 'id = ?', whereArgs: [id]);
              _cargar();
              if (mounted) Navigator.pop(ctx);

              if (prefs.getBool('es_premium') ?? false) {
                ServicioNube.eliminarClienteNube(id);
              }
            },
            child: const Text(
              'ELIMINAR',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isOscuro
          ? const Color(0xFF0A0A0F)
          : const Color(0xFFF2F4F7),
      appBar: AppBar(
        title: _buscando
            ? TextField(
                controller: _searchCtrl,
                autofocus: true,
                style: const TextStyle(color: Colors.white, fontSize: 15),
                decoration: const InputDecoration(
                  hintText: "Buscar cliente o teléfono...",
                  hintStyle: TextStyle(color: Colors.white70),
                  border: InputBorder.none,
                ),
                onChanged: _filtrar,
              )
            : const Text(
                'Clientes',
                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17),
              ),
        backgroundColor: isOscuro
            ? const Color(0xFF0D1B2A)
            : const Color(0xFF0D47A1),
        foregroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(
              _buscando ? Icons.close_rounded : Icons.search_rounded,
              color: Colors.white,
              size: 22,
            ),
            tooltip: _buscando ? "Cerrar búsqueda" : "Buscar",
            onPressed: () {
              setState(() {
                if (_buscando) {
                  _buscando = false;
                  _searchCtrl.clear();
                  _filtrados = _clientes;
                } else {
                  _buscando = true;
                }
              });
            },
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ==========================================
            // ENCABEZADO CON NOMBRE REAL Y CONTADOR
            // ==========================================
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      const Icon(
                        Icons.people_alt_rounded,
                        size: 20,
                        color: Color(0xFF0D47A1),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "CLIENTES (${_nombreNegocio.toUpperCase()})",
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w900,
                                color: isOscuro
                                    ? Colors.white70
                                    : Colors.blueGrey.shade800,
                                letterSpacing: 0.5,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              "Clientes activos: ${_filtrados.length}",
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: isOscuro
                                    ? Colors.cyanAccent
                                    : const Color(0xFF0D47A1),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0D47A1),
                    foregroundColor: Colors.white,
                    elevation: 2,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: () => _abrirFormulario(),
                  icon: const Icon(Icons.add_rounded, size: 16),
                  label: const Text(
                    "Nuevo",
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            if (_filtrados.isEmpty)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(22),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: isOscuro ? Colors.white10 : Colors.black12,
                  ),
                ),
                child: Column(
                  children: [
                    Icon(
                      Icons.people_outline_rounded,
                      size: 44,
                      color: Colors.grey.shade400,
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      "No hay clientes registrados",
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 15),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF0D47A1),
                        foregroundColor: Colors.white,
                      ),
                      onPressed: () => _abrirFormulario(),
                      child: const Text("Registrar Primer Cliente"),
                    ),
                  ],
                ),
              )
            else
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _filtrados.length,
                itemBuilder: (ctx, i) {
                  final c = _filtrados[i];
                  final int pedidosCompletos =
                      (c['pedidos_completos'] as num?)?.toInt() ?? 0;
                  final String direccion = (c['direccion'] ?? '')
                      .toString()
                      .trim();
                  final String telFormateado = _formatearTelefono(
                    c['telefono'],
                  );

                  return Card(
                    color: Theme.of(context).cardColor,
                    margin: const EdgeInsets.only(bottom: 14),
                    elevation: isOscuro ? 0 : 3,
                    shadowColor: Colors.black12,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(22),
                      side: BorderSide(
                        color: isOscuro
                            ? Colors.cyanAccent.withOpacity(0.3)
                            : const Color(0xFF0D47A1).withOpacity(0.2),
                        width: 1.5,
                      ),
                    ),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(22),
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => PantallaDetalleCliente(cliente: c),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 52,
                                  height: 52,
                                  decoration: BoxDecoration(
                                    color: isOscuro
                                        ? Colors.white10
                                        : Colors.grey.shade200,
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(
                                      color: isOscuro
                                          ? Colors.cyanAccent
                                          : const Color(0xFF0D47A1),
                                      width: 1.5,
                                    ),
                                  ),
                                  child: Icon(
                                    Icons.person_rounded,
                                    color: isOscuro
                                        ? Colors.cyanAccent
                                        : const Color(0xFF0D47A1),
                                    size: 26,
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        c['nombre_completo'] ?? 'Cliente',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w900,
                                          fontSize: 16,
                                          color: isOscuro
                                              ? Colors.white
                                              : Colors.black87,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        "📞 $telFormateado",
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: isOscuro
                                              ? Colors.cyanAccent
                                              : const Color(0xFF0D47A1),
                                        ),
                                      ),
                                      if (direccion.isNotEmpty) ...[
                                        const SizedBox(height: 2),
                                        Text(
                                          "📍 $direccion",
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: isOscuro
                                                ? Colors.white38
                                                : Colors.grey.shade600,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                PopupMenuButton<String>(
                                  icon: const Icon(
                                    Icons.more_vert,
                                    size: 20,
                                    color: Colors.grey,
                                  ),
                                  onSelected: (val) {
                                    if (val == 'edit') {
                                      _abrirFormulario(cliente: c);
                                    } else if (val == 'delete') {
                                      _eliminar(c['id'], c['nombre_completo']);
                                    }
                                  },
                                  itemBuilder: (ctx) => [
                                    const PopupMenuItem(
                                      value: 'edit',
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.edit,
                                            size: 16,
                                            color: Colors.orange,
                                          ),
                                          SizedBox(width: 8),
                                          Text("Editar"),
                                        ],
                                      ),
                                    ),
                                    const PopupMenuItem(
                                      value: 'delete',
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.delete_outline,
                                            size: 16,
                                            color: Colors.red,
                                          ),
                                          SizedBox(width: 8),
                                          Text(
                                            "Eliminar",
                                            style: TextStyle(color: Colors.red),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),

                            const SizedBox(height: 12),

                            // RECUADRO DE PEDIDOS COMPLETOS
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: isOscuro
                                    ? Colors.cyanAccent.withOpacity(0.07)
                                    : Colors.blue.shade50.withOpacity(0.7),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: isOscuro
                                      ? Colors.cyanAccent.withOpacity(0.2)
                                      : Colors.blue.shade100,
                                ),
                              ),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        Icons.shopping_bag_rounded,
                                        color: isOscuro
                                            ? Colors.cyanAccent
                                            : const Color(0xFF0D47A1),
                                        size: 16,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        "Pedidos Completos: $pedidosCompletos",
                                        style: TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: isOscuro
                                              ? Colors.cyanAccent
                                              : const Color(0xFF0D47A1),
                                        ),
                                      ),
                                    ],
                                  ),
                                  Icon(
                                    Icons.verified_rounded,
                                    color: isOscuro
                                        ? Colors.cyanAccent
                                        : const Color(0xFF0D47A1),
                                    size: 16,
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(height: 10),

                            // ACCIÓN INTERACTIVA ÚNICA
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  "👉 Toque para ver información del cliente",
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w800,
                                    color: isOscuro
                                        ? Colors.orangeAccent
                                        : Colors.orange.shade900,
                                  ),
                                ),
                                Icon(
                                  Icons.arrow_forward_ios_rounded,
                                  size: 11,
                                  color: isOscuro
                                      ? Colors.white38
                                      : Colors.grey.shade600,
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),

            // BANNER PUBLICIDAD NO PREMIUM IDÉNTICO A FIDELIDAD
            if (!_esPremium) ...[
              const SizedBox(height: 20),
              const AnuncioNativoWidget(key: ValueKey('admob_client_list_ad')),
            ],
          ],
        ),
      ),
    );
  }
}

class PantallaDetalleCliente extends StatelessWidget {
  final Map<String, dynamic> cliente;
  const PantallaDetalleCliente({super.key, required this.cliente});

  @override
  Widget build(BuildContext context) {
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isOscuro
          ? const Color(0xFF0A0A0F)
          : const Color(0xFFF8F9FA),
      appBar: AppBar(
        title: const Text("Información del Cliente"),
        backgroundColor: isOscuro
            ? const Color(0xFF0D1B2A)
            : const Color(0xFF0D47A1),
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(25),
        child: Column(
          children: [
            Icon(
              Icons.person_pin,
              size: 80,
              color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1),
            ),
            const SizedBox(height: 15),
            Text(
              cliente['nombre_completo'],
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: isOscuro ? Colors.white : Colors.black,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              "Teléfono: ${cliente['telefono']}",
              style: TextStyle(
                fontSize: 16,
                color: isOscuro ? Colors.white60 : Colors.grey,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              "Dirección: ${cliente['direccion'] ?? 'No registrada'}",
              style: TextStyle(
                fontSize: 14,
                color: isOscuro ? Colors.white38 : Colors.blueGrey,
              ),
            ),
            const SizedBox(height: 30),
            FutureBuilder<List<Map<String, dynamic>>>(
              future: DBHelper.instance.database.then(
                (db) => db.query(
                  'pedidos',
                  where: 'cliente_id = ?',
                  whereArgs: [cliente['id']],
                ),
              ),
              builder: (context, snapshot) {
                if (!snapshot.hasData)
                  return const Center(child: CircularProgressIndicator());

                double totalComprado = snapshot.data!.fold(
                  0,
                  (sum, it) => sum + (it['total_venta'] as double),
                );

                return Column(
                  children: [
                    _cardInfo(
                      "PEDIDOS REALIZADOS",
                      snapshot.data!.length.toString(),
                      Icons.shopping_bag,
                      Colors.blue,
                      isOscuro,
                    ),
                    const SizedBox(height: 15),
                    _cardInfo(
                      "TOTAL COMPRADO",
                      "\$${totalComprado.toStringAsFixed(0)}",
                      Icons.monetization_on,
                      Colors.greenAccent,
                      isOscuro,
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _cardInfo(String t, String v, IconData i, Color c, bool isOscuro) =>
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: isOscuro ? c.withOpacity(0.05) : c.withOpacity(0.1),
          borderRadius: BorderRadius.circular(15),
          border: Border.all(
            color: isOscuro ? c.withOpacity(0.2) : c.withOpacity(0.3),
          ),
        ),
        child: Row(
          children: [
            Icon(i, color: c, size: 30),
            const SizedBox(width: 20),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: isOscuro ? c.withOpacity(0.7) : c,
                  ),
                ),
                Text(
                  v,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: isOscuro ? Colors.white : c.withOpacity(0.9),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
}

class PantallaFormularioCliente extends StatefulWidget {
  final Map<String, dynamic>? cliente;
  final VoidCallback onGuardar;

  const PantallaFormularioCliente({
    super.key,
    this.cliente,
    required this.onGuardar,
  });

  @override
  State<PantallaFormularioCliente> createState() =>
      _PantallaFormularioClienteState();
}

class _PantallaFormularioClienteState extends State<PantallaFormularioCliente> {
  final _nCtrl = TextEditingController();
  final _negocioCtrl =
      TextEditingController(); // 🏪 Campo opcional para negocio
  final _indCtrl =
      TextEditingController(); // 🌐 Inicia vacío (el +57 es solo ejemplo/hint)
  final _tCtrl = TextEditingController();
  final _dCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.cliente != null) {
      _nCtrl.text = widget.cliente!['nombre_completo'] ?? '';
      _negocioCtrl.text =
          widget.cliente!['nombre_negocio'] ?? widget.cliente!['empresa'] ?? '';
      _dCtrl.text = widget.cliente!['direccion'] ?? '';

      String telGuardado = (widget.cliente!['telefono'] ?? '')
          .toString()
          .trim();
      _extraerIndicativoYNumero(telGuardado);
    }
  }

  // Desglosa el teléfono guardado si se está editando
  void _extraerIndicativoYNumero(String tel) {
    String limpio = tel.replaceAll(RegExp(r'\s+'), '');
    if (limpio.isEmpty) return;

    if (limpio.startsWith('+')) {
      if (limpio.length > 10) {
        _indCtrl.text = limpio.substring(0, limpio.length - 10);
        _tCtrl.text = limpio.substring(limpio.length - 10);
      } else {
        _indCtrl.text = "+57";
        _tCtrl.text = limpio.replaceAll('+', '');
      }
    } else if (limpio.startsWith('57') && limpio.length == 12) {
      _indCtrl.text = "+57";
      _tCtrl.text = limpio.substring(2);
    } else if (limpio.length > 10 && RegExp(r'^\d+$').hasMatch(limpio)) {
      _indCtrl.text = "+${limpio.substring(0, limpio.length - 10)}";
      _tCtrl.text = limpio.substring(limpio.length - 10);
    } else {
      _tCtrl.text = limpio;
    }
  }

  @override
  void dispose() {
    _nCtrl.dispose();
    _negocioCtrl.dispose();
    _indCtrl.dispose();
    _tCtrl.dispose();
    _dCtrl.dispose();
    super.dispose();
  }

  Future<void> _guardar() async {
    String nombre = _nCtrl.text.trim();
    String ind = _indCtrl.text.trim();
    String numTel = _tCtrl.text.trim().replaceAll(RegExp(r'\D'), '');

    // VALIDACIÓN DE NOMBRE
    if (nombre.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('⚠️ El nombre del cliente es obligatorio'),
        ),
      );
      return;
    }

    // VALIDACIÓN DE INDICATIVO
    if (ind.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('⚠️ El indicativo del país es obligatorio (ej: +57)'),
        ),
      );
      return;
    }

    // Limpieza de indicativo (elimina caracteres que no sean dígitos)
    String indLimpio = ind.replaceAll(RegExp(r'\D'), '');
    if (indLimpio.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('⚠️ Ingresa un indicativo numérico válido (ej: +57)'),
        ),
      );
      return;
    }

    // VALIDACIÓN DE NÚMERO
    if (numTel.isEmpty || numTel.length < 7) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            '⚠️ Ingresa un número de teléfono válido (mínimo 7 a 10 dígitos)',
          ),
        ),
      );
      return;
    }

    // Teléfono unificado con indicativo (ej: 573245656171)
    String telefonoCompleto = "$indLimpio$numTel";

    final db = await DBHelper.instance.database;
    final prefs = await SharedPreferences.getInstance();

    final datos = {
      'nombre_completo': nombre,
      'nombre_negocio': _negocioCtrl.text.trim(),
      'telefono': telefonoCompleto,
      'direccion': _dCtrl.text.trim(),
    };

    bool esNuevo = widget.cliente == null;
    int idActual;

    try {
      if (esNuevo) {
        idActual = await db.insert('clientes', datos);
      } else {
        idActual = widget.cliente!['id'];
        await db.update(
          'clientes',
          datos,
          where: 'id = ?',
          whereArgs: [idActual],
        );
      }
    } catch (_) {
      // En caso de que la columna nombre_negocio aún no exista en versiones locales antiguas
      datos.remove('nombre_negocio');
      if (esNuevo) {
        idActual = await db.insert('clientes', datos);
      } else {
        idActual = widget.cliente!['id'];
        await db.update(
          'clientes',
          datos,
          where: 'id = ?',
          whereArgs: [idActual],
        );
      }
    }

    widget.onGuardar();

    if (prefs.getBool('es_premium') ?? false) {
      ServicioNube.guardarClienteNube({...datos, 'id': idActual});
    }

    if (mounted) {
      if (esNuevo) {
        ServicioAnuncios.mostrarAnuncioIntersticial(() {
          if (mounted) Navigator.pop(context);
        });
      } else {
        Navigator.pop(context);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: isOscuro ? const Color(0xFF0A0A0F) : Colors.white,
      appBar: AppBar(
        title: Text(
          widget.cliente == null ? 'Nuevo Cliente' : 'Editar Cliente',
        ),
        backgroundColor: isOscuro
            ? const Color(0xFF0D1B2A)
            : const Color(0xFF0D47A1),
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const SizedBox(height: 10),
            Icon(
              Icons.person_add_alt_1,
              size: 80,
              color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1),
            ),
            const SizedBox(height: 25),

            // 1. NOMBRE COMPLETO (OBLIGATORIO)
            _buildInput(_nCtrl, 'Nombre Completo *', Icons.person, isOscuro),
            const SizedBox(height: 15),

            // 2. NOMBRE DEL NEGOCIO (OPCIONAL)
            _buildInput(
              _negocioCtrl,
              'Nombre del Negocio (Opcional)',
              Icons.storefront_rounded,
              isOscuro,
            ),
            const SizedBox(height: 15),

            // 3. INDICATIVO + TELÉFONO (OBLIGATORIOS)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Indicativo (Inicia vacío con hint '+57')
                SizedBox(
                  width: 105,
                  child: TextField(
                    controller: _indCtrl,
                    keyboardType: TextInputType.phone,
                    style: TextStyle(
                      color: isOscuro ? Colors.white : Colors.black,
                      fontWeight: FontWeight.bold,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Ind *',
                      hintText: '+57',
                      hintStyle: TextStyle(
                        color: isOscuro ? Colors.white38 : Colors.black26,
                      ),
                      labelStyle: TextStyle(
                        fontSize: 12,
                        color: isOscuro ? Colors.white60 : Colors.black54,
                      ),
                      prefixIcon: Icon(
                        Icons.public_rounded,
                        size: 18,
                        color: isOscuro
                            ? Colors.cyanAccent
                            : const Color(0xFF0D47A1),
                      ),
                      filled: true,
                      fillColor: isOscuro
                          ? Colors.white.withOpacity(0.05)
                          : Colors.grey.shade50,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: isOscuro ? Colors.white10 : Colors.black12,
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 14,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),

                // Teléfono
                Expanded(
                  child: TextField(
                    controller: _tCtrl,
                    keyboardType: TextInputType.phone,
                    style: TextStyle(
                      color: isOscuro ? Colors.white : Colors.black,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Teléfono *',
                      hintText: 'Ej: 3245656171',
                      hintStyle: TextStyle(
                        color: isOscuro ? Colors.white38 : Colors.black26,
                      ),
                      labelStyle: TextStyle(
                        color: isOscuro ? Colors.white60 : Colors.black54,
                      ),
                      prefixIcon: Icon(
                        Icons.phone,
                        color: isOscuro
                            ? Colors.cyanAccent
                            : const Color(0xFF0D47A1),
                      ),
                      filled: true,
                      fillColor: isOscuro
                          ? Colors.white.withOpacity(0.05)
                          : Colors.grey.shade50,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(
                          color: isOscuro ? Colors.white10 : Colors.black12,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 15),

            // 4. DIRECCIÓN (OPCIONAL)
            _buildInput(
              _dCtrl,
              'Dirección (Opcional)',
              Icons.location_on,
              isOscuro,
            ),
            const SizedBox(height: 40),

            // BOTÓN GUARDAR
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: isOscuro
                    ? Colors.cyanAccent.shade700
                    : const Color(0xFF0D47A1),
                foregroundColor: isOscuro ? Colors.black : Colors.white,
                minimumSize: const Size(double.infinity, 55),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: _guardar,
              child: const Text(
                "GUARDAR CLIENTE",
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInput(
    TextEditingController ctrl,
    String label,
    IconData icon,
    bool isOscuro, {
    TextInputType keyboard = TextInputType.text,
  }) {
    return TextField(
      controller: ctrl,
      keyboardType: keyboard,
      style: TextStyle(color: isOscuro ? Colors.white : Colors.black),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(
          color: isOscuro ? Colors.white60 : Colors.black54,
        ),
        prefixIcon: Icon(
          icon,
          color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1),
        ),
        filled: true,
        fillColor: isOscuro
            ? Colors.white.withOpacity(0.05)
            : Colors.grey.shade50,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: isOscuro ? Colors.white10 : Colors.black12,
          ),
        ),
      ),
    );
  }
}

class AnuncioNativoWidget extends StatefulWidget {
  const AnuncioNativoWidget({super.key});

  @override
  State<AnuncioNativoWidget> createState() => _AnuncioNativoWidgetState();
}

class _AnuncioNativoWidgetState extends State<AnuncioNativoWidget> {
  BannerAd? _bannerAd;
  bool _isLoaded = false;

  final String _adUnitId = Platform.isAndroid
      ? 'ca-app-pub-2754846263403564/3464101852'
      : 'ca-app-pub-3940256099942544/2934735716';

  @override
  void initState() {
    super.initState();
    _cargarAnuncio();
  }

  void _cargarAnuncio() {
    _bannerAd = BannerAd(
      adUnitId: _adUnitId,
      request: const AdRequest(),
      size: AdSize.largeBanner,
      listener: BannerAdListener(
        onAdLoaded: (ad) {
          if (mounted) setState(() => _isLoaded = true);
        },
        onAdFailedToLoad: (ad, error) {
          debugPrint('Error cargando banner seguro: ${error.message}');
          ad.dispose();
        },
      ),
    )..load();
  }

  @override
  void dispose() {
    _bannerAd?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isOscuro = Theme.of(context).brightness == Brightness.dark;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
      decoration: BoxDecoration(
        color: isOscuro ? const Color(0xFF1E2230) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isOscuro ? Colors.white10 : Colors.grey.shade300,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 14),
            color: isOscuro
                ? Colors.white.withOpacity(0.05)
                : Colors.grey.shade50,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  "Publicidad Recomendada",
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: isOscuro ? Colors.white54 : Colors.grey.shade600,
                  ),
                ),
                Icon(
                  Icons.info_outline,
                  size: 12,
                  color: isOscuro ? Colors.white54 : Colors.grey.shade400,
                ),
              ],
            ),
          ),
          Container(
            height: 120,
            alignment: Alignment.center,
            color: isOscuro ? Colors.black26 : Colors.grey.shade50,
            child: _isLoaded && _bannerAd != null
                ? AdWidget(ad: _bannerAd!)
                : InkWell(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const PantallaPremium(),
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.stars,
                          color: Colors.amber.shade700,
                          size: 24,
                        ),
                        const SizedBox(width: 12),
                        const Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "¿Respaldar base de datos?",
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                            Text(
                              "Sincroniza tus clientes y pedidos en tiempo real.",
                              style: TextStyle(
                                color: Colors.grey,
                                fontSize: 10,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
          ),
          InkWell(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const PantallaPremium()),
            ),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: isOscuro ? Colors.white10 : Colors.black12,
                  ),
                ),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.workspace_premium, size: 16, color: Colors.orange),
                  SizedBox(width: 8),
                  Text(
                    "QUITAR PUBLICIDAD (HAZTE PRO)",
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      color: Colors.orange,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
