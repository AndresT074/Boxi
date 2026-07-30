import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ServicioNotificaciones {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const String _canalPedidosId = 'pedidos_web_urgente';
  static const String _canalPedidosNombre = 'Pedidos Web Nuevos';
  static const String _canalInactividadId = 'inactividad';
  static const String _canalInactividadNombre = 'Recordatorios';

  // 🔥 Callback global que se activa cuando el cliente TOCA la notificación
  static Function(String token)? onFidelidadTap;

  static Future<void> inicializar() async {
    const AndroidInitializationSettings androidInit =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initSettings =
        InitializationSettings(android: androidInit);

    await _plugin.initialize(
      settings: initSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) async {
        // 🔥 SI EL CLIENTE TOCA LA NOTIFICACIÓN: Guarda el token y abre la ficha directo
        if (response.payload != null && response.payload!.isNotEmpty) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('pending_fidelidad_token', response.payload!);
          onFidelidadTap?.call(response.payload!);
        }
      },
    );

    final androidPlugin = _plugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

    if (androidPlugin != null) {
      await androidPlugin.requestNotificationsPermission();

      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          _canalPedidosId,
          _canalPedidosNombre,
          description: 'Notificaciones de pedidos en tiempo real',
          importance: Importance.max,
          playSound: true,
          enableVibration: true,
          showBadge: true,
        ),
      );

      await androidPlugin.createNotificationChannel(
        const AndroidNotificationChannel(
          _canalInactividadId,
          _canalInactividadNombre,
          description: 'Recordatorios de uso de la app',
          importance: Importance.high,
        ),
      );
    }
  }

  static Future<void> mostrarNotificacionInactividad(String titulo, String cuerpo) async {
    int notificationId = 99999;
    await _plugin.show(
      id: notificationId,
      title: titulo,
      body: cuerpo,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _canalInactividadId,
          _canalInactividadNombre,
          channelDescription: 'Recordatorios de uso de la app',
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
        ),
      ),
    );
  }

  static Future<void> mostrarNotificacionPedido(
      String nombreNegocio, String nombreCliente) async {
    int notificationId = DateTime.now().millisecondsSinceEpoch % 100000;
    await _plugin.show(
      id: notificationId,
      title: '📦 ¡Nuevo Pedido Web!',
      body: 'Hola $nombreNegocio, $nombreCliente te hizo un pedido.',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _canalPedidosId,
          _canalPedidosNombre,
          channelDescription: 'Notificaciones de nuevos pedidos desde la web',
          importance: Importance.max,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
          playSound: true,
          enableVibration: true,
        ),
      ),
    );
  }

  // 🔥 Notificación de Fidelidad flotante de alta prioridad
  static Future<void> mostrarNotificacionFidelidad(
      String titulo, String cuerpo, {String? token}) async {
    int notificationId = DateTime.now().millisecondsSinceEpoch % 100000;
    await _plugin.show(
      id: notificationId,
      title: titulo,
      body: cuerpo,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _canalPedidosId, // 👈 Usa el canal de máxima importancia igual a pedidos web
          _canalPedidosNombre,
          channelDescription: 'Notificaciones de puntos de fidelidad',
          importance: Importance.max, // 👈 Fuerza el aviso flotante en pantalla
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
          playSound: true,
          enableVibration: true,
        ),
      ),
      payload: token ?? '',
    );
  }
}