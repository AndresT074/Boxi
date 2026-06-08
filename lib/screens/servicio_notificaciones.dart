import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class ServicioNotificaciones {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const String _canalPedidosId = 'pedidos_web_urgente';
  static const String _canalPedidosNombre = 'Pedidos Web Nuevos';
  static const String _canalInactividadId = 'inactividad';
  static const String _canalInactividadNombre = 'Recordatorios';

  // Inicializa los canales necesarios para recibir las notificaciones push de Firebase
  static Future<void> inicializar() async {
    const AndroidInitializationSettings androidInit =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initSettings =
        InitializationSettings(android: androidInit);

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {},
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

  // Dibuja la notificación en pantalla cuando Firebase recibe una campaña de inactividad con la app abierta
  static Future<void> mostrarNotificacionInactividad(String titulo, String cuerpo) async {
    int notificationId = 99999; // ID fijo para que se sobrescriba y no llene la barra
    await _plugin.show(
      notificationId,
      titulo,
      cuerpo,
      const NotificationDetails(
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

  // Dibuja la notificación en pantalla cuando Firebase recibe un pedido web en tiempo real
  static Future<void> mostrarNotificacionPedido(
      String nombreNegocio, String nombreCliente) async {
    int notificationId = DateTime.now().millisecondsSinceEpoch % 100000;
    await _plugin.show(
      notificationId,
      '📦 ¡Nuevo Pedido Web!',
      'Hola $nombreNegocio, $nombreCliente te hizo un pedido.',
      const NotificationDetails(
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
}