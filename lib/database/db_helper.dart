import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DBHelper {
  static final DBHelper instance = DBHelper._init();
  static Database? _database;

  DBHelper._init();

  static const String dbName = 'boxi_pro_database.db';

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB(dbName);
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);
    return await openDatabase(
      path,
      version: 19,
      onCreate: _createDB,
      onUpgrade: _onUpgrade,
    );
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''CREATE TABLE vendedores (id INTEGER PRIMARY KEY AUTOINCREMENT, nombre TEXT NOT NULL, telefono TEXT, email TEXT, ultima_modificacion TEXT)''');
    await db.execute('''CREATE TABLE clientes (id INTEGER PRIMARY KEY AUTOINCREMENT, nombre_completo TEXT NOT NULL, nombre_negocio TEXT, direccion TEXT, telefono TEXT, departamento TEXT, ciudad TEXT, firma TEXT, ultima_modificacion TEXT)''');
    await db.execute('''CREATE TABLE productos (id INTEGER PRIMARY KEY AUTOINCREMENT, nombre TEXT NOT NULL, foto_path TEXT, precio_compra REAL NOT NULL, precio_venta REAL NOT NULL, descuento REAL DEFAULT 0, stock INTEGER DEFAULT 0, descripcion TEXT, variantes TEXT, orden INTEGER DEFAULT 0, activo INTEGER DEFAULT 1, ultima_modificacion TEXT, categoria TEXT)''');
    await db.execute('''CREATE TABLE pedidos (id INTEGER PRIMARY KEY AUTOINCREMENT, fecha_hora TEXT NOT NULL, fecha_pago TEXT, cliente_id INTEGER NOT NULL, vendedor_id INTEGER NOT NULL, total_venta REAL NOT NULL, ganancia_total REAL NOT NULL, estado TEXT NOT NULL, departamento TEXT, ciudad TEXT, firma BLOB, valor_domicilio REAL DEFAULT 0, cliente_nombre_snapshot TEXT, ultima_modificacion TEXT)'''); // ✅ Agregada columna fecha_pago
    await db.execute('''CREATE TABLE detalle_pedidos (id INTEGER PRIMARY KEY AUTOINCREMENT, pedido_id INTEGER NOT NULL, producto_id INTEGER NOT NULL, cantidad INTEGER NOT NULL, precio_unitario REAL NOT NULL, subtotal REAL NOT NULL, nombre_snapshot TEXT, descuento REAL DEFAULT 0, ultima_modificacion TEXT, FOREIGN KEY (pedido_id) REFERENCES pedidos (id) ON DELETE CASCADE)''');
    await db.execute('''CREATE TABLE ajustes_capital (id INTEGER PRIMARY KEY AUTOINCREMENT, monto REAL NOT NULL, fecha TEXT NOT NULL, descripcion TEXT, ultima_modificacion TEXT)''');
    await db.execute('''CREATE TABLE reportes_guardados (id INTEGER PRIMARY KEY AUTOINCREMENT, titulo TEXT, fecha TEXT, caja REAL, utilidad REAL, reinversion REAL, detalle_json TEXT, ultima_modificacion TEXT)''');
    await db.execute('''CREATE TABLE operaciones_pendientes (id INTEGER PRIMARY KEY AUTOINCREMENT, tabla TEXT NOT NULL, operacion TEXT NOT NULL, doc_id TEXT NOT NULL, datos_json TEXT, fecha_creacion TEXT NOT NULL)''');
    await db.execute('''
      CREATE TABLE fotos_variantes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        producto_id INTEGER NOT NULL,
        grupo_index INTEGER NOT NULL,
        opcion_index INTEGER NOT NULL,
        variante_nombre TEXT,
        foto_base64 TEXT NOT NULL,
        ultima_modificacion TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE categorias (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        nombre TEXT UNIQUE NOT NULL,
        activo INTEGER DEFAULT 1,
        orden INTEGER DEFAULT 0, 
        ultima_modificacion TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE tarjetas_fidelidad (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        titulo TEXT NOT NULL,
        meta_compras INTEGER NOT NULL,
        premio_descripcion TEXT,
        monto_minimo REAL DEFAULT 0,
        activa INTEGER DEFAULT 1,
        ultima_modificacion TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE puntos_clientes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        cliente_id INTEGER NOT NULL,
        tarjeta_id INTEGER NOT NULL,
        puntos_actuales INTEGER DEFAULT 0,
        completadas_totales INTEGER DEFAULT 0,
        ultima_modificacion TEXT,
        FOREIGN KEY (cliente_id) REFERENCES clientes (id) ON DELETE CASCADE,
        FOREIGN KEY (tarjeta_id) REFERENCES tarjetas_fidelidad (id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE tokens_qr_usados (
        id TEXT PRIMARY KEY,
        cliente_id INTEGER NOT NULL,
        tarjeta_id INTEGER NOT NULL,
        fecha_uso TEXT NOT NULL
      )
    ''');
  }

  Future _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 12) {
      try { await db.execute('ALTER TABLE productos ADD COLUMN descripcion TEXT'); } catch (_) {}
      try { await db.execute('ALTER TABLE productos ADD COLUMN variantes TEXT'); } catch (_) {}
      try { await db.execute('ALTER TABLE productos ADD COLUMN orden INTEGER DEFAULT 0'); } catch (_) {}
      try { await db.execute('ALTER TABLE productos ADD COLUMN activo INTEGER DEFAULT 1'); } catch (_) {}
      try { await db.execute('ALTER TABLE productos ADD COLUMN descuento REAL DEFAULT 0'); } catch (_) {}
      try { await db.execute('ALTER TABLE pedidos ADD COLUMN valor_domicilio REAL DEFAULT 0'); } catch (_) {}
      try { await db.execute('ALTER TABLE detalle_pedidos ADD COLUMN descuento REAL DEFAULT 0'); } catch (_) {}
      try { await db.execute('ALTER TABLE detalle_pedidos ADD COLUMN nombre_snapshot TEXT'); } catch (_) {}
      try { await db.execute('''UPDATE detalle_pedidos SET nombre_snapshot = (SELECT nombre FROM productos WHERE productos.id = detalle_pedidos.producto_id) WHERE nombre_snapshot IS NULL OR nombre_snapshot = '' '''); } catch (_) {}
      try { await db.execute('ALTER TABLE productos ADD COLUMN ultima_modificacion TEXT'); } catch (_) {}
      try { await db.execute('ALTER TABLE clientes ADD COLUMN ultima_modificacion TEXT'); } catch (_) {}
      try { await db.execute('ALTER TABLE pedidos ADD COLUMN ultima_modificacion TEXT'); } catch (_) {}
      try { await db.execute('ALTER TABLE vendedores ADD COLUMN ultima_modificacion TEXT'); } catch (_) {}
      try { await db.execute('ALTER TABLE detalle_pedidos ADD COLUMN ultima_modificacion TEXT'); } catch (_) {}
      try { await db.execute('ALTER TABLE reportes_guardados ADD COLUMN ultima_modificacion TEXT'); } catch (_) {}
      try { await db.execute('ALTER TABLE ajustes_capital ADD COLUMN ultima_modificacion TEXT'); } catch (_) {}
      try { await db.execute('''CREATE TABLE IF NOT EXISTS operaciones_pendientes (id INTEGER PRIMARY KEY AUTOINCREMENT, tabla TEXT NOT NULL, operacion TEXT NOT NULL, doc_id TEXT NOT NULL, datos_json TEXT, fecha_creacion TEXT NOT NULL)'''); } catch (_) {}
      try { await db.execute('''CREATE TABLE IF NOT EXISTS fotos_variantes (id INTEGER PRIMARY KEY AUTOINCREMENT, producto_id INTEGER NOT NULL, grupo_index INTEGER NOT NULL, opcion_index INTEGER NOT NULL, foto_base64 TEXT NOT NULL, ultima_modificacion TEXT)'''); } catch (_) {}
    }
    
    if (oldVersion < 13) {
      try { await db.execute('ALTER TABLE fotos_variantes ADD COLUMN variante_nombre TEXT'); } catch (_) {}
    }

    if (oldVersion < 14) {
      try { await db.execute('ALTER TABLE productos ADD COLUMN categoria TEXT DEFAULT NULL'); } catch (_) {}
      try { await db.execute('''
        CREATE TABLE IF NOT EXISTS categorias (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          nombre TEXT UNIQUE NOT NULL,
          activo INTEGER DEFAULT 1,
          orden INTEGER DEFAULT 0,
          ultima_modificacion TEXT
        )
      '''); } catch (_) {}
    }
    if (oldVersion < 16) {
      try { await db.execute('ALTER TABLE pedidos ADD COLUMN cliente_nombre_snapshot TEXT DEFAULT NULL'); } catch (_) {}
      try { await db.execute('''UPDATE pedidos SET cliente_nombre_snapshot = (SELECT nombre_completo FROM clientes WHERE clientes.id = pedidos.cliente_id) WHERE cliente_nombre_snapshot IS NULL OR cliente_nombre_snapshot = ""'''); } catch (_) {}
    }
    // 🔥 MIGRACIÓN DE LA VERSIÓN 17 (Fecha de pago independiente)
    if (oldVersion < 17) {
      try { await db.execute('ALTER TABLE pedidos ADD COLUMN fecha_pago TEXT DEFAULT NULL'); } catch (_) {}
      // Saneamiento: Para pedidos antiguos ya completados, rellenamos fecha_pago con su fecha de pedido original
      try { await db.execute("UPDATE pedidos SET fecha_pago = fecha_hora WHERE estado = 'Completado' AND (fecha_pago IS NULL OR fecha_pago = '')"); } catch (_) {}
    }
    // 🔥 MIGRACIÓN DE LA VERSIÓN 18 (Sistema de Fidelidad)
    if (oldVersion < 18) {
      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS tarjetas_fidelidad (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            titulo TEXT NOT NULL,
            meta_compras INTEGER NOT NULL,
            premio_descripcion TEXT,
            activa INTEGER DEFAULT 1,
            ultima_modificacion TEXT
          )
        ''');
      } catch (_) {}

      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS puntos_clientes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            cliente_id INTEGER NOT NULL,
            tarjeta_id INTEGER NOT NULL,
            puntos_actuales INTEGER DEFAULT 0,
            completadas_totales INTEGER DEFAULT 0,
            ultima_modificacion TEXT
          )
        ''');
      } catch (_) {}

      try {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS tokens_qr_usados (
            id TEXT PRIMARY KEY,
            cliente_id INTEGER NOT NULL,
            tarjeta_id INTEGER NOT NULL,
            fecha_uso TEXT NOT NULL
          )
        ''');
      } catch (_) {}
    }

    // 🔥 MIGRACIÓN DE LA VERSIÓN 19 (Monto mínimo en tarjetas de fidelidad)
    if (oldVersion < 19) {
      try { await db.execute('ALTER TABLE tarjetas_fidelidad ADD COLUMN monto_minimo REAL DEFAULT 0'); } catch (_) {}
    }
  }

  Future<void> close() async { final db = _database; if (db != null) { await db.close(); _database = null; } }
  
  Future<void> limpiarTablas() async {
    final db = await database;
    await db.delete('vendedores'); await db.delete('clientes'); await db.delete('productos');
    await db.delete('pedidos'); await db.delete('detalle_pedidos'); await db.delete('ajustes_capital');
    await db.delete('reportes_guardados'); await db.delete('operaciones_pendientes');
    try { await db.delete('fotos_variantes'); } catch (_) {}
    try { await db.delete('categorias'); } catch (_) {} 
    try { await db.delete('tarjetas_fidelidad'); } catch (_) {}
    try { await db.delete('puntos_clientes'); } catch (_) {}
    try { await db.delete('tokens_qr_usados'); } catch (_) {}
  }
}