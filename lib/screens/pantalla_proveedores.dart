import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import '../database/db_helper.dart';
import 'servicio_nube.dart';
import 'servicio_anuncios.dart';
import 'pantalla_premium.dart';
import 'dart:async';

class PantallaProveedores extends StatefulWidget {
  const PantallaProveedores({super.key});
  @override
  State<PantallaProveedores> createState() => _PantallaProveedoresState();
}

class _PantallaProveedoresState extends State<PantallaProveedores> {
  StreamSubscription? _suscripcion;
  List<Map<String, dynamic>> _proveedores = [];
  List<Map<String, dynamic>> _filtrados = [];
  String _nombreNegocio = "MI NEGOCIO";
  bool _esPremium = false;
  final _searchCtrl = TextEditingController();
  bool _mostrandoBusqueda = false;

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
    final data = await db.query('proveedores', orderBy: 'id DESC');

    String nombreNeg = prefs.getString('nombre_negocio') ?? "MI NEGOCIO";

    if (!mounted) return;
    setState(() {
      _nombreNegocio = nombreNeg;
      _proveedores = data;
      _filtrados = data;
      _esPremium = prefs.getBool('es_premium') ?? false;
    });
  }

  void _filtrar(String q) {
    setState(() {
      _filtrados = _proveedores
          .where(
            (p) =>
                p['nombre'].toString().toLowerCase().contains(
                  q.toLowerCase(),
                ) ||
                (p['telefono'] ?? '').toString().contains(q),
          )
          .toList();
    });
  }

  void _abrirFormulario({Map<String, dynamic>? proveedor}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (context) => PantallaFormularioProveedor(
          proveedor: proveedor,
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
            Icon(
              Icons.delete_forever_rounded,
              color: Colors.redAccent,
              size: 28,
            ),
            SizedBox(width: 8),
            Text(
              '¿Eliminar Proveedor?',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
            ),
          ],
        ),
        content: Text(
          '¿Estás seguro de que deseas eliminar a "$nombre"? Los productos asociados se mantendrán pero quedarán sin proveedor asignado.',
        ),
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

              await db.delete('proveedores', where: 'id = ?', whereArgs: [id]);
              await db.rawUpdate(
                'UPDATE productos SET proveedor_id = NULL WHERE proveedor_id = ?',
                [id],
              );

              _cargar();
              if (mounted) Navigator.pop(ctx);

              if (prefs.getBool('es_premium') ?? false) {
                await ServicioNube.eliminarProveedorNube(id);
                await ServicioNube.respaldarDatosPrivadosRTDB();
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
        elevation: 0,
        backgroundColor: isOscuro
            ? const Color(0xFF0D1B2A)
            : const Color(0xFF0D47A1),
        foregroundColor: Colors.white,
        centerTitle: false,
        title: _mostrandoBusqueda
            ? TextField(
                controller: _searchCtrl,
                autofocus: true,
                style: const TextStyle(color: Colors.white, fontSize: 15),
                decoration: const InputDecoration(
                  hintText: 'Buscar proveedor o teléfono...',
                  hintStyle: TextStyle(color: Colors.white60, fontSize: 14),
                  border: InputBorder.none,
                ),
                onChanged: _filtrar,
              )
            : const Text(
                'Proveedores',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 18,
                  color: Colors.white,
                  letterSpacing: 0.5,
                ),
              ),
        actions: [
          IconButton(
            icon: Icon(
              _mostrandoBusqueda ? Icons.close_rounded : Icons.search_rounded,
              color: Colors.white,
              size: 24,
            ),
            tooltip: _mostrandoBusqueda
                ? 'Cerrar búsqueda'
                : 'Buscar proveedor',
            onPressed: () {
              setState(() {
                _mostrandoBusqueda = !_mostrandoBusqueda;
                if (!_mostrandoBusqueda) {
                  _searchCtrl.clear();
                  _filtrar('');
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
                        Icons.local_shipping_rounded,
                        size: 20,
                        color: Color(0xFF0D47A1),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              "PROVEEDORES (${_nombreNegocio.toUpperCase()})",
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
                              "Proveedores activos: ${_filtrados.length}",
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
                      Icons.local_shipping_outlined,
                      size: 60,
                      color: isOscuro ? Colors.white12 : Colors.black12,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'No hay proveedores registrados',
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
                      child: const Text("Registrar Primer Proveedor"),
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
                  final prov = _filtrados[i];
                  String tel = prov['telefono']?.toString() ?? '';
                  String ind = prov['indicativo']?.toString() ?? '57';
                  bool tieneWhatsApp = tel.isNotEmpty;

                  return Card(
                    elevation: isOscuro ? 0 : 3,
                    margin: const EdgeInsets.only(bottom: 14),
                    color: Theme.of(context).cardColor,
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
                          builder: (_) =>
                              PantallaDetalleProveedor(proveedor: prov),
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
                                    Icons.local_shipping_rounded,
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
                                        prov['nombre'],
                                        style: TextStyle(
                                          fontWeight: FontWeight.w900,
                                          fontSize: 16,
                                          color: isOscuro
                                              ? Colors.white
                                              : Colors.black87,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      const SizedBox(height: 3),
                                      Row(
                                        children: [
                                          Icon(
                                            tieneWhatsApp
                                                ? Icons.phone_android_rounded
                                                : Icons.phone_disabled_rounded,
                                            size: 14,
                                            color: tieneWhatsApp
                                                ? const Color(0xFF25D366)
                                                : Colors.grey,
                                          ),
                                          const SizedBox(width: 4),
                                          Expanded(
                                            child: Text(
                                              tieneWhatsApp
                                                  ? "+$ind $tel"
                                                  : "Sin teléfono registrado",
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                                color: tieneWhatsApp
                                                    ? (isOscuro
                                                          ? Colors.cyanAccent
                                                          : const Color(
                                                              0xFF0D47A1,
                                                            ))
                                                    : Colors.grey,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: Icon(
                                        Icons.edit_note_rounded,
                                        color: isOscuro
                                            ? Colors.cyanAccent
                                            : const Color(0xFF0D47A1),
                                        size: 24,
                                      ),
                                      tooltip: "Editar",
                                      onPressed: () =>
                                          _abrirFormulario(proveedor: prov),
                                    ),
                                    IconButton(
                                      icon: const Icon(
                                        Icons.delete_outline_rounded,
                                        color: Colors.redAccent,
                                        size: 22,
                                      ),
                                      tooltip: "Eliminar",
                                      onPressed: () =>
                                          _eliminar(prov['id'], prov['nombre']),
                                    ),
                                  ],
                                ),
                              ],
                            ),

                            const SizedBox(height: 12),
                            Divider(
                              height: 1,
                              color: isOscuro
                                  ? Colors.white10
                                  : Colors.grey.shade200,
                            ),
                            const SizedBox(height: 10),

                            // ACCIÓN INTERACTIVA ÚNICA
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  "👉 Toca para hacer un pedido al proveedor",
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

            // BANNER PUBLICITARIO NO PREMIUM
            if (!_esPremium) ...[
              const SizedBox(height: 20),
              const AnuncioNativoWidget(
                key: ValueKey('admob_provider_list_ad'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// 🏢 FORMULARIO DE PROVEEDOR
class PantallaFormularioProveedor extends StatefulWidget {
  final Map<String, dynamic>? proveedor;
  final VoidCallback onGuardar;

  const PantallaFormularioProveedor({
    super.key,
    this.proveedor,
    required this.onGuardar,
  });

  @override
  State<PantallaFormularioProveedor> createState() =>
      _PantallaFormularioProveedorState();
}

class _PantallaFormularioProveedorState
    extends State<PantallaFormularioProveedor> {
  final _nCtrl = TextEditingController();
  final _eCtrl = TextEditingController();
  final _indCtrl = TextEditingController(); // Inicia vacío (hint: 57)
  final _tCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.proveedor != null) {
      _nCtrl.text = widget.proveedor!['nombre'] ?? '';
      _eCtrl.text = widget.proveedor!['email'] ?? '';
      _indCtrl.text = widget.proveedor!['indicativo'] ?? '';
      _tCtrl.text = widget.proveedor!['telefono'] ?? '';
    }
  }

  @override
  void dispose() {
    _nCtrl.dispose();
    _eCtrl.dispose();
    _indCtrl.dispose();
    _tCtrl.dispose();
    super.dispose();
  }

  Future<void> _guardar() async {
    String nombre = _nCtrl.text.trim();
    if (nombre.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('⚠️ El nombre del proveedor es obligatorio'),
        ),
      );
      return;
    }

    final db = await DBHelper.instance.database;
    final prefs = await SharedPreferences.getInstance();

    String indFinal = _indCtrl.text.trim().replaceAll(RegExp(r'\D'), '');
    if (indFinal.isEmpty) indFinal = '57';

    final datos = {
      'nombre': nombre,
      'indicativo': indFinal,
      'telefono': _tCtrl.text.trim().replaceAll(RegExp(r'\D'), ''),
      'email': _eCtrl.text.trim(),
      'ultima_modificacion': DateTime.now().toIso8601String(),
    };

    bool esNuevo = widget.proveedor == null;
    int idActual;
    if (esNuevo) {
      idActual = await db.insert('proveedores', datos);
    } else {
      idActual = widget.proveedor!['id'];
      await db.update(
        'proveedores',
        datos,
        where: 'id = ?',
        whereArgs: [idActual],
      );
    }

    widget.onGuardar();

    if (prefs.getBool('es_premium') ?? false) {
      await ServicioNube.guardarProveedorNube({...datos, 'id': idActual});
      await ServicioNube.respaldarDatosPrivadosRTDB();
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
          widget.proveedor == null ? 'Nuevo Proveedor' : 'Editar Proveedor',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
        ),
        backgroundColor: isOscuro
            ? const Color(0xFF0D1B2A)
            : const Color(0xFF0D47A1),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: isOscuro
                        ? [
                            Colors.cyanAccent.withOpacity(0.2),
                            Colors.blueAccent.withOpacity(0.1),
                          ]
                        : [const Color(0xFF0D47A1), const Color(0xFF1976D2)],
                  ),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.local_shipping_rounded,
                  size: 55,
                  color: isOscuro ? Colors.cyanAccent : Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 25),

            // 1. NOMBRE DEL PROVEEDOR
            Text(
              "NOMBRE DEL PROVEEDOR *",
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w900,
                color: isOscuro ? Colors.white60 : Colors.grey.shade700,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _nCtrl,
              style: TextStyle(
                color: isOscuro ? Colors.white : Colors.black87,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
              decoration: InputDecoration(
                hintText: "Ej: Distribuidora Central",
                hintStyle: TextStyle(
                  color: isOscuro ? Colors.white38 : Colors.grey.shade400,
                  fontSize: 13,
                ),
                prefixIcon: Icon(
                  Icons.person,
                  color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1),
                  size: 20,
                ),
                filled: true,
                fillColor: isOscuro
                    ? Colors.white.withOpacity(0.05)
                    : Colors.grey.shade100,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 18),

            // 2. CORREO ELECTRÓNICO
            Text(
              "CORREO ELECTRÓNICO (OPCIONAL)",
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w900,
                color: isOscuro ? Colors.white60 : Colors.grey.shade700,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _eCtrl,
              keyboardType: TextInputType.emailAddress,
              style: TextStyle(
                color: isOscuro ? Colors.white : Colors.black87,
                fontSize: 14,
              ),
              decoration: InputDecoration(
                hintText: "ejemplo@correo.com",
                hintStyle: TextStyle(
                  color: isOscuro ? Colors.white38 : Colors.grey.shade400,
                  fontSize: 13,
                ),
                prefixIcon: Icon(
                  Icons.email_outlined,
                  color: isOscuro ? Colors.cyanAccent : const Color(0xFF0D47A1),
                  size: 20,
                ),
                filled: true,
                fillColor: isOscuro
                    ? Colors.white.withOpacity(0.05)
                    : Colors.grey.shade100,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 18),

            // 3. WHATSAPP (INDICATIVO Y NÚMERO)
            Row(
              children: [
                SizedBox(
                  width: 90,
                  child: Text(
                    "INDICATIVO",
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w900,
                      color: isOscuro ? Colors.white60 : Colors.grey.shade700,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    "WHATSAPP (OPCIONAL)",
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w900,
                      color: isOscuro ? Colors.white60 : Colors.grey.shade700,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                SizedBox(
                  width: 90,
                  child: TextField(
                    controller: _indCtrl,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: isOscuro ? Colors.white : Colors.black87,
                      fontWeight: FontWeight.w900,
                      fontSize: 15,
                    ),
                    decoration: InputDecoration(
                      prefixText: "+",
                      hintText: "57",
                      hintStyle: TextStyle(
                        color: isOscuro ? Colors.white38 : Colors.black26,
                      ),
                      prefixStyle: TextStyle(
                        color: isOscuro
                            ? Colors.cyanAccent
                            : const Color(0xFF0D47A1),
                        fontWeight: FontWeight.w900,
                        fontSize: 15,
                      ),
                      filled: true,
                      fillColor: isOscuro
                          ? Colors.white.withOpacity(0.05)
                          : Colors.grey.shade100,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 14,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _tCtrl,
                    keyboardType: TextInputType.phone,
                    style: TextStyle(
                      color: isOscuro ? Colors.white : Colors.black87,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                    decoration: InputDecoration(
                      hintText: "Ej: 3123456789",
                      hintStyle: TextStyle(
                        color: isOscuro ? Colors.white38 : Colors.grey.shade400,
                        fontSize: 13,
                      ),
                      prefixIcon: Icon(
                        Icons.phone_iphone_rounded,
                        color: isOscuro
                            ? Colors.cyanAccent
                            : const Color(0xFF0D47A1),
                        size: 20,
                      ),
                      filled: true,
                      fillColor: isOscuro
                          ? Colors.white.withOpacity(0.05)
                          : Colors.grey.shade100,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 14,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 35),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: isOscuro
                    ? Colors.cyanAccent.shade700
                    : const Color(0xFF0D47A1),
                foregroundColor: isOscuro ? Colors.black : Colors.white,
                minimumSize: const Size(double.infinity, 55),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                elevation: 3,
              ),
              icon: const Icon(Icons.check_circle_rounded, size: 20),
              label: const Text(
                "GUARDAR PROVEEDOR",
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 14,
                  letterSpacing: 0.5,
                ),
              ),
              onPressed: _guardar,
            ),
          ],
        ),
      ),
    );
  }
}

// 📦 DETALLE DE PROVEEDOR
class PantallaDetalleProveedor extends StatefulWidget {
  final Map<String, dynamic> proveedor;
  const PantallaDetalleProveedor({super.key, required this.proveedor});

  @override
  State<PantallaDetalleProveedor> createState() =>
      _PantallaDetalleProveedorState();
}

class _PantallaDetalleProveedorState extends State<PantallaDetalleProveedor> {
  List<Map<String, dynamic>> _productos = [];
  List<Map<String, dynamic>> _historialCompras = [];

  final Map<int, Map<String, int>> _variantesSeleccionadasPorProd = {};
  final Map<int, int> _cantidadesSimples = {};
  final Set<int> _productosSimplesSeleccionados = {};

  final TextEditingController _busquedaCtrl = TextEditingController();
  String _queryBusqueda = "";

  double _inversionTotalProveedor = 0;
  int _unidadesTotalesProveedor = 0;
  bool _cargando = true;

  @override
  void initState() {
    super.initState();
    _cargarDetalles();
  }

  @override
  void dispose() {
    _busquedaCtrl.dispose();
    super.dispose();
  }

  Future<void> _cargarDetalles() async {
    final db = await DBHelper.instance.database;
    int provId = widget.proveedor['id'];

    final prods = await db.query(
      'productos',
      where: 'proveedor_id = ?',
      whereArgs: [provId],
      orderBy: 'nombre ASC',
    );
    final compras = await db.query(
      'ajustes_capital',
      where: 'proveedor_id = ?',
      whereArgs: [provId],
      orderBy: 'id DESC',
    );

    double invTotal = 0;
    int cantTotal = 0;

    for (var p in prods) {
      double pCompra = (p['precio_compra'] as num?)?.toDouble() ?? 0.0;
      String varStr = p['variantes']?.toString() ?? '';
      bool tieneVariantes = false;

      if (varStr.length > 5) {
        try {
          var dec = jsonDecode(varStr);
          if (dec is List && dec.isNotEmpty) {
            tieneVariantes = true;
            for (var g in dec) {
              if (g is Map && g['opciones'] is List) {
                for (var o in g['opciones']) {
                  if (o is Map && (o['activo'] ?? true) == true) {
                    int stOpc = (o['stock'] as num?)?.toInt() ?? 0;
                    invTotal += (pCompra * (stOpc > 0 ? stOpc : 0));
                    cantTotal += (stOpc > 0 ? stOpc : 0);
                  }
                }
              }
            }
          }
        } catch (_) {}
      }

      if (!tieneVariantes) {
        int st = (p['stock'] as num?)?.toInt() ?? 0;
        invTotal += (pCompra * (st > 0 ? st : 0));
        cantTotal += (st > 0 ? st : 0);
        int pId = p['id'] as int;
        _cantidadesSimples.putIfAbsent(pId, () => 0);
      }
    }

    if (mounted) {
      setState(() {
        _productos = prods;
        _historialCompras = compras;
        _inversionTotalProveedor = invTotal;
        _unidadesTotalesProveedor = cantTotal;
        _cargando = false;
      });
    }
  }

  Widget _construirMiniatura(String fotoPath, {double size = 44}) {
    if (fotoPath.isEmpty) {
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.grey.shade200,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(Icons.image, size: size * 0.5, color: Colors.grey),
      );
    }
    if (fotoPath.startsWith('http')) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.network(
          fotoPath,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) =>
              Icon(Icons.broken_image, size: size * 0.5),
        ),
      );
    }
    if (fotoPath.length > 500) {
      try {
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.memory(
            base64Decode(fotoPath),
            width: size,
            height: size,
            fit: BoxFit.cover,
          ),
        );
      } catch (_) {}
    }
    try {
      File f = File(fotoPath);
      if (f.existsSync()) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.file(f, width: size, height: size, fit: BoxFit.cover),
        );
      }
    } catch (_) {}
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.grey.shade200,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(Icons.broken_image, size: size * 0.5),
    );
  }

  void _abrirSelectorVariantes(Map<String, dynamic> p, List<dynamic> grps) {
    int pId = p['id'];
    _variantesSeleccionadasPorProd.putIfAbsent(pId, () => {});
    Map<String, int> tempCantidades = Map.from(
      _variantesSeleccionadasPorProd[pId]!,
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setStModal) {
          final isOscuro = Theme.of(context).brightness == Brightness.dark;

          return Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.8,
            ),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
            ),
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.grey.shade400,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 15),
                Row(
                  children: [
                    _construirMiniatura(
                      p['foto_path']?.toString() ?? '',
                      size: 48,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            p['nombre'].toString(),
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              fontSize: 16,
                            ),
                          ),
                          const Text(
                            "Selecciona cantidades para pedir:",
                            style: TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Divider(),
                Expanded(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: grps.length,
                    itemBuilder: (context, gIdx) {
                      var g = grps[gIdx];
                      List opciones = (g is Map && g['opciones'] is List)
                          ? g['opciones']
                          : [];
                      String grupoNom = (g['grupo'] ?? 'Opciones').toString();

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 8,
                              horizontal: 4,
                            ),
                            child: Text(
                              grupoNom.toUpperCase(),
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: isOscuro
                                    ? Colors.cyanAccent
                                    : Colors.blueGrey,
                              ),
                            ),
                          ),
                          ...opciones
                              .asMap()
                              .entries
                              .where((e) => (e.value['activo'] ?? true) == true)
                              .map((e) {
                                int oIdx = e.key;
                                var o = e.value;
                                String key = "${gIdx}_$oIdx";
                                int stockVar =
                                    (o['stock'] as num?)?.toInt() ?? 0;
                                String fotoVar =
                                    (o['foto_path']?.toString().isNotEmpty ==
                                        true)
                                    ? o['foto_path'].toString()
                                    : (p['foto_path']?.toString() ?? '');
                                int cantActual = tempCantidades[key] ?? 0;

                                return Container(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: cantActual > 0
                                        ? (isOscuro
                                              ? Colors.cyanAccent.withOpacity(
                                                  0.08,
                                                )
                                              : Colors.green.shade50)
                                        : (isOscuro
                                              ? Colors.white.withOpacity(0.03)
                                              : Colors.grey.shade50),
                                    borderRadius: BorderRadius.circular(14),
                                    border: Border.all(
                                      color: cantActual > 0
                                          ? const Color(0xFF25D366)
                                          : (isOscuro
                                                ? Colors.white10
                                                : Colors.grey.shade200),
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      _construirMiniatura(fotoVar, size: 40),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              o['nombre'].toString(),
                                              style: const TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 13,
                                              ),
                                            ),
                                            Text(
                                              stockVar <= 0
                                                  ? "Agotado (0 u.)"
                                                  : "Quedan: $stockVar unidades",
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: stockVar <= 0
                                                    ? Colors.redAccent
                                                    : Colors.grey,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            icon: const Icon(
                                              Icons.remove_circle_outline,
                                              color: Colors.red,
                                              size: 22,
                                            ),
                                            onPressed: () {
                                              if (cantActual > 0) {
                                                setStModal(() {
                                                  int nuevo = cantActual - 1;
                                                  if (nuevo == 0)
                                                    tempCantidades.remove(key);
                                                  else
                                                    tempCantidades[key] = nuevo;
                                                });
                                              }
                                            },
                                          ),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 4,
                                            ),
                                            decoration: BoxDecoration(
                                              color: cantActual > 0
                                                  ? (isOscuro
                                                        ? Colors.cyanAccent
                                                              .withOpacity(0.2)
                                                        : Colors.green.shade100)
                                                  : Colors.transparent,
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                            child: Text(
                                              "$cantActual",
                                              style: TextStyle(
                                                fontWeight: FontWeight.w900,
                                                fontSize: 15,
                                                color: cantActual > 0
                                                    ? (isOscuro
                                                          ? Colors.cyanAccent
                                                          : Colors
                                                                .green
                                                                .shade900)
                                                    : Colors.grey,
                                              ),
                                            ),
                                          ),
                                          IconButton(
                                            icon: const Icon(
                                              Icons.add_circle_outline,
                                              color: Colors.green,
                                              size: 22,
                                            ),
                                            onPressed: () {
                                              setStModal(() {
                                                tempCantidades[key] =
                                                    (tempCantidades[key] ?? 0) +
                                                    1;
                                              });
                                            },
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                );
                              })
                              .toList(),
                        ],
                      );
                    },
                  ),
                ),
                const SizedBox(height: 10),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0D47A1),
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 50),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: () {
                    setState(() {
                      _variantesSeleccionadasPorProd[pId] = tempCantidades;
                    });
                    Navigator.pop(ctx);
                  },
                  child: const Text(
                    "ACEPTAR Y DESPLEGAR",
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _enviarPedidoConsolidadoWhatsApp() async {
    String tel =
        widget.proveedor['telefono']?.toString().replaceAll(
          RegExp(r'\D'),
          '',
        ) ??
        '';
    String ind =
        widget.proveedor['indicativo']?.toString().replaceAll(
          RegExp(r'\D'),
          '',
        ) ??
        '57';
    String fullNum = "$ind$tel";

    if (tel.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "⚠️ Este proveedor no tiene número de WhatsApp registrado.",
          ),
        ),
      );
      return;
    }

    String provNombre = widget.proveedor['nombre'] ?? 'Proveedor';
    StringBuffer sb = StringBuffer();
    sb.writeln("Hola *$provNombre*, necesito el siguiente pedido:\n");

    bool hayItems = false;

    // 1. Productos simples
    for (int pId in _productosSimplesSeleccionados) {
      int cant = _cantidadesSimples[pId] ?? 0;
      if (cant > 0) {
        var prod = _productos.firstWhere(
          (p) => p['id'] == pId,
          orElse: () => {},
        );
        if (prod.isNotEmpty) {
          sb.writeln("• *${prod['nombre']}*: $cant unidades");
          hayItems = true;
        }
      }
    }

    // 2. Productos con variantes
    for (var entry in _variantesSeleccionadasPorProd.entries) {
      int pId = entry.key;
      var prod = _productos.firstWhere((p) => p['id'] == pId, orElse: () => {});
      if (prod.isNotEmpty && entry.value.isNotEmpty) {
        String varStr = prod['variantes']?.toString() ?? '';
        try {
          var dec = jsonDecode(varStr);
          if (dec is List) {
            sb.writeln("• *${prod['nombre']}*:");
            for (var vEntry in entry.value.entries) {
              if (vEntry.value > 0) {
                List<String> partes = vEntry.key.split('_');
                int gIdx = int.parse(partes[0]);
                int oIdx = int.parse(partes[1]);
                var o = dec[gIdx]['opciones'][oIdx];
                sb.writeln("   ↳ *${o['nombre']}*: ${vEntry.value} unidades");
                hayItems = true;
              }
            }
          }
        } catch (_) {}
      }
    }

    if (!hayItems) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "⚠️ Aumenta la cantidad de al menos un producto para pedir.",
          ),
        ),
      );
      return;
    }

    sb.writeln("\nMuchas gracias.");
    String textEncoded = Uri.encodeComponent(sb.toString());

    Uri uriApp = Uri.parse("whatsapp://send?phone=$fullNum&text=$textEncoded");
    Uri uriWeb = Uri.parse("https://wa.me/$fullNum?text=$textEncoded");

    try {
      if (await canLaunchUrl(uriApp)) {
        await launchUrl(uriApp, mode: LaunchMode.externalApplication);
      } else {
        await launchUrl(uriWeb, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final bool isOscuro = Theme.of(context).brightness == Brightness.dark;
    String nombre = widget.proveedor['nombre'] ?? 'Proveedor';

    int totalItemsSeleccionados = 0;
    for (int pId in _productosSimplesSeleccionados) {
      if ((_cantidadesSimples[pId] ?? 0) > 0) totalItemsSeleccionados++;
    }
    for (var vMap in _variantesSeleccionadasPorProd.values) {
      for (var cant in vMap.values) {
        if (cant > 0) totalItemsSeleccionados++;
      }
    }

    final prodsFiltrados = _productos.where((p) {
      String q = _queryBusqueda.toLowerCase();
      return p['nombre'].toString().toLowerCase().contains(q);
    }).toList();

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: isOscuro
            ? const Color(0xFF0A0A0F)
            : const Color(0xFFF8F9FA),
        appBar: AppBar(
          title: Text(
            nombre,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
          ),
          backgroundColor: isOscuro
              ? const Color(0xFF0D1B2A)
              : const Color(0xFF0D47A1),
          foregroundColor: Colors.white,
          bottom: const TabBar(
            indicatorColor: Colors.cyanAccent,
            labelColor: Colors.cyanAccent,
            unselectedLabelColor: Colors.white60,
            tabs: [
              Tab(icon: Icon(Icons.inventory_2_outlined), text: "PRODUCTOS"),
              Tab(icon: Icon(Icons.history_rounded), text: "HISTORIAL COMPRAS"),
            ],
          ),
        ),
        bottomNavigationBar: totalItemsSeleccionados > 0
            ? Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 10,
                      offset: const Offset(0, -2),
                    ),
                  ],
                ),
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF25D366),
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 50),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  icon: const Icon(Icons.send_rounded),
                  label: Text(
                    "PEDIR REPOSICIÓN ($totalItemsSeleccionados) POR WHATSAPP",
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                    ),
                  ),
                  onPressed: _enviarPedidoConsolidadoWhatsApp,
                ),
              )
            : null,
        body: _cargando
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                children: [
                  // ==========================================
                  // TAB 1: PRODUCTOS CON BUSCADOR Y SELECCIÓN
                  // ==========================================
                  Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
                        child: TextField(
                          controller: _busquedaCtrl,
                          onChanged: (v) =>
                              setState(() => _queryBusqueda = v.trim()),
                          decoration: InputDecoration(
                            hintText: "Buscar producto del proveedor...",
                            prefixIcon: const Icon(Icons.search, size: 20),
                            suffixIcon: _queryBusqueda.isNotEmpty
                                ? IconButton(
                                    icon: const Icon(Icons.close, size: 18),
                                    onPressed: () {
                                      _busquedaCtrl.clear();
                                      setState(() => _queryBusqueda = "");
                                    },
                                  )
                                : null,
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            filled: true,
                            fillColor: isOscuro
                                ? Colors.white.withOpacity(0.05)
                                : Colors.white,
                          ),
                        ),
                      ),

                      Expanded(
                        child: prodsFiltrados.isEmpty
                            ? Center(
                                child: Text(
                                  "No hay productos asignados a este proveedor.\nEdita un producto en inventario y asígnalo aquí.",
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: isOscuro
                                        ? Colors.white38
                                        : Colors.grey,
                                  ),
                                ),
                              )
                            : ListView.separated(
                                padding: const EdgeInsets.fromLTRB(
                                  14,
                                  8,
                                  14,
                                  85,
                                ),
                                itemCount: prodsFiltrados.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 10),
                                itemBuilder: (ctx, i) {
                                  var p = prodsFiltrados[i];
                                  int pId = p['id'] as int;
                                  int stock =
                                      (p['stock'] as num?)?.toInt() ?? 0;
                                  String varStr =
                                      p['variantes']?.toString() ?? '';

                                  List<dynamic> grps = [];
                                  bool tieneVariantes = false;
                                  if (varStr.length > 5) {
                                    try {
                                      var dec = jsonDecode(varStr);
                                      if (dec is List && dec.isNotEmpty) {
                                        tieneVariantes = true;
                                        grps = dec;
                                      }
                                    } catch (_) {}
                                  }

                                  int cantSimple = _cantidadesSimples[pId] ?? 0;
                                  bool isSimpleSel =
                                      _productosSimplesSeleccionados.contains(
                                        pId,
                                      ) &&
                                      cantSimple > 0;
                                  bool hasVariantesSel =
                                      _variantesSeleccionadasPorProd
                                          .containsKey(pId) &&
                                      _variantesSeleccionadasPorProd[pId]!
                                          .values
                                          .any((v) => v > 0);

                                  return Card(
                                    elevation: 1,
                                    color: (isSimpleSel || hasVariantesSel)
                                        ? (isOscuro
                                              ? Colors.cyanAccent.withOpacity(
                                                  0.08,
                                                )
                                              : Colors.green.shade50)
                                        : Theme.of(context).cardColor,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16),
                                      side: BorderSide(
                                        color: (isSimpleSel || hasVariantesSel)
                                            ? const Color(0xFF25D366)
                                            : (isOscuro
                                                  ? Colors.white10
                                                  : Colors.grey.shade200),
                                      ),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.all(12.0),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              _construirMiniatura(
                                                p['foto_path']?.toString() ??
                                                    '',
                                                size: 46,
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Text(
                                                      p['nombre'].toString(),
                                                      style: const TextStyle(
                                                        fontWeight:
                                                            FontWeight.bold,
                                                        fontSize: 14,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 3),
                                                    Text(
                                                      stock <= 0
                                                          ? "Agotado (0 u.)"
                                                          : "Quedan: $stock unidades",
                                                      style: TextStyle(
                                                        fontSize: 12,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                        color: stock <= 0
                                                            ? Colors.redAccent
                                                            : (isOscuro
                                                                  ? Colors
                                                                        .white60
                                                                  : Colors
                                                                        .grey
                                                                        .shade700),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),

                                              if (tieneVariantes)
                                                ElevatedButton.icon(
                                                  style: ElevatedButton.styleFrom(
                                                    backgroundColor:
                                                        hasVariantesSel
                                                        ? const Color(
                                                            0xFF25D366,
                                                          )
                                                        : (isOscuro
                                                              ? Colors
                                                                    .cyanAccent
                                                                    .withOpacity(
                                                                      0.15,
                                                                    )
                                                              : const Color(
                                                                  0xFF0D47A1,
                                                                ).withOpacity(
                                                                  0.1,
                                                                )),
                                                    foregroundColor:
                                                        hasVariantesSel
                                                        ? Colors.white
                                                        : (isOscuro
                                                              ? Colors
                                                                    .cyanAccent
                                                              : const Color(
                                                                  0xFF0D47A1,
                                                                )),
                                                    elevation: 0,
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 12,
                                                          vertical: 8,
                                                        ),
                                                    shape: RoundedRectangleBorder(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            12,
                                                          ),
                                                    ),
                                                  ),
                                                  icon: Icon(
                                                    hasVariantesSel
                                                        ? Icons.check_circle
                                                        : Icons.tune_rounded,
                                                    size: 16,
                                                  ),
                                                  label: Text(
                                                    hasVariantesSel
                                                        ? "Elegidas (${_variantesSeleccionadasPorProd[pId]!.length})"
                                                        : "Variantes",
                                                    style: const TextStyle(
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                    ),
                                                  ),
                                                  onPressed: () =>
                                                      _abrirSelectorVariantes(
                                                        p,
                                                        grps,
                                                      ),
                                                )
                                              else
                                                Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    IconButton(
                                                      icon: const Icon(
                                                        Icons
                                                            .remove_circle_outline,
                                                        size: 22,
                                                        color: Colors.red,
                                                      ),
                                                      onPressed: () {
                                                        if (cantSimple > 0) {
                                                          setState(() {
                                                            int nuevo =
                                                                cantSimple - 1;
                                                            _cantidadesSimples[pId] =
                                                                nuevo;
                                                            if (nuevo == 0)
                                                              _productosSimplesSeleccionados
                                                                  .remove(pId);
                                                          });
                                                        }
                                                      },
                                                    ),
                                                    Text(
                                                      "$cantSimple",
                                                      style: TextStyle(
                                                        fontWeight:
                                                            FontWeight.w900,
                                                        fontSize: 15,
                                                        color: cantSimple > 0
                                                            ? (isOscuro
                                                                  ? Colors
                                                                        .cyanAccent
                                                                  : Colors
                                                                        .green
                                                                        .shade900)
                                                            : Colors.grey,
                                                      ),
                                                    ),
                                                    IconButton(
                                                      icon: const Icon(
                                                        Icons
                                                            .add_circle_outline,
                                                        size: 22,
                                                        color: Colors.green,
                                                      ),
                                                      onPressed: () {
                                                        setState(() {
                                                          _cantidadesSimples[pId] =
                                                              cantSimple + 1;
                                                          _productosSimplesSeleccionados
                                                              .add(pId);
                                                        });
                                                      },
                                                    ),
                                                  ],
                                                ),
                                            ],
                                          ),

                                          if (tieneVariantes &&
                                              hasVariantesSel) ...[
                                            const SizedBox(height: 10),
                                            Container(
                                              padding: const EdgeInsets.all(10),
                                              decoration: BoxDecoration(
                                                color: isOscuro
                                                    ? Colors.black26
                                                    : Colors.white,
                                                borderRadius:
                                                    BorderRadius.circular(14),
                                                border: Border.all(
                                                  color: isOscuro
                                                      ? Colors.white10
                                                      : Colors.black12,
                                                ),
                                              ),
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Row(
                                                    mainAxisAlignment:
                                                        MainAxisAlignment
                                                            .spaceBetween,
                                                    children: [
                                                      const Text(
                                                        "Variantes seleccionadas para pedir:",
                                                        style: TextStyle(
                                                          fontSize: 11,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                          color: Colors.grey,
                                                        ),
                                                      ),
                                                      InkWell(
                                                        onTap: () => setState(
                                                          () =>
                                                              _variantesSeleccionadasPorProd
                                                                  .remove(pId),
                                                        ),
                                                        child: const Text(
                                                          "Quitar todas",
                                                          style: TextStyle(
                                                            fontSize: 11,
                                                            color: Colors
                                                                .redAccent,
                                                            fontWeight:
                                                                FontWeight.bold,
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                  const SizedBox(height: 6),
                                                  ..._variantesSeleccionadasPorProd[pId]!
                                                      .entries
                                                      .where((v) => v.value > 0)
                                                      .map((vEntry) {
                                                        List<String> partes =
                                                            vEntry.key.split(
                                                              '_',
                                                            );
                                                        int gIdx = int.parse(
                                                          partes[0],
                                                        );
                                                        int oIdx = int.parse(
                                                          partes[1],
                                                        );
                                                        var o =
                                                            grps[gIdx]['opciones'][oIdx];
                                                        int stVar =
                                                            (o['stock'] as num?)
                                                                ?.toInt() ??
                                                            0;

                                                        return Padding(
                                                          padding:
                                                              const EdgeInsets.symmetric(
                                                                vertical: 3,
                                                              ),
                                                          child: Row(
                                                            mainAxisAlignment:
                                                                MainAxisAlignment
                                                                    .spaceBetween,
                                                            children: [
                                                              Text(
                                                                "• ${o['nombre']} (Quedan: $stVar u.)",
                                                                style: const TextStyle(
                                                                  fontSize: 12,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w600,
                                                                ),
                                                              ),
                                                              Text(
                                                                "${vEntry.value} u.",
                                                                style: TextStyle(
                                                                  fontSize: 13,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w900,
                                                                  color:
                                                                      isOscuro
                                                                      ? Colors
                                                                            .greenAccent
                                                                      : const Color(
                                                                          0xFF25D366,
                                                                        ),
                                                                ),
                                                              ),
                                                            ],
                                                          ),
                                                        );
                                                      })
                                                      .toList(),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),

                  // ==========================================
                  // TAB 2: HISTORIAL DE COMPRAS Y RESUMEN
                  // ==========================================
                  ListView(
                    padding: const EdgeInsets.all(15),
                    children: [
                      Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: isOscuro
                                ? [
                                    const Color(0xFF1E3A8A),
                                    const Color(0xFF0F172A),
                                  ]
                                : [
                                    const Color(0xFF0D47A1),
                                    const Color(0xFF1976D2),
                                  ],
                          ),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  "Inversión en Bodega",
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  "\$${_inversionTotalProveedor.toStringAsFixed(0)}",
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 22,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ],
                            ),
                            Container(
                              width: 1,
                              height: 40,
                              color: Colors.white24,
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  "Stock Disponible",
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  "$_unidadesTotalesProveedor unidades",
                                  style: const TextStyle(
                                    color: Colors.cyanAccent,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),

                      const Text(
                        "VALORIZACIÓN DE PRODUCTOS EN STOCK",
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ..._productos.map((p) {
                        double costo =
                            (p['precio_compra'] as num?)?.toDouble() ?? 0.0;
                        int st = (p['stock'] as num?)?.toInt() ?? 0;
                        double totalCosto = costo * (st > 0 ? st : 0);

                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          color: Theme.of(context).cardColor,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: ListTile(
                            dense: true,
                            leading: _construirMiniatura(
                              p['foto_path']?.toString() ?? '',
                            ),
                            title: Text(
                              p['nombre'].toString(),
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                            subtitle: Text(
                              "Costo: \$${costo.toStringAsFixed(0)}  •  Quedan: $st u.",
                            ),
                            trailing: Text(
                              "\$${totalCosto.toStringAsFixed(0)}",
                              style: TextStyle(
                                color: isOscuro
                                    ? Colors.greenAccent
                                    : Colors.green.shade800,
                                fontWeight: FontWeight.w900,
                                fontSize: 14,
                              ),
                            ),
                          ),
                        );
                      }).toList(),

                      const SizedBox(height: 20),

                      if (_historialCompras.isNotEmpty) ...[
                        const Text(
                          "HISTORIAL DE COMPRAS / REINVERSIONES",
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ..._historialCompras.map((c) {
                          double monto =
                              (c['monto'] as num?)?.toDouble() ?? 0.0;
                          String desc = c['descripcion'] ?? 'Compra de stock';
                          String fecha =
                              c['fecha']?.toString().substring(0, 10) ?? '';

                          return Card(
                            margin: const EdgeInsets.only(bottom: 8),
                            color: Theme.of(context).cardColor,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: ListTile(
                              dense: true,
                              leading: const CircleAvatar(
                                backgroundColor: Colors.redAccent,
                                radius: 14,
                                child: Icon(
                                  Icons.arrow_downward,
                                  color: Colors.white,
                                  size: 14,
                                ),
                              ),
                              title: Text(
                                desc,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                              subtitle: Text("📅 $fecha"),
                              trailing: Text(
                                "-\$${monto.abs().toStringAsFixed(0)}",
                                style: const TextStyle(
                                  color: Colors.redAccent,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          );
                        }),
                      ],
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

// 🏷️ CLASE DEL ANUNCIO NATIVO HÍBRIDO (IDÉNTICA A FIDELIDAD)
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
                              "Sincroniza tus proveedores e inventario en tiempo real.",
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
