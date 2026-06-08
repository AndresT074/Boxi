import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ServicioTema {
  static final ValueNotifier<ThemeMode> modoTema = ValueNotifier(ThemeMode.light);

  static Future<void> cargar() async {
    final prefs = await SharedPreferences.getInstance();
    bool oscuro = prefs.getBool('modo_oscuro') ?? false;
    modoTema.value = oscuro ? ThemeMode.dark : ThemeMode.light;
  }

  static Future<void> alternar(bool activar) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('modo_oscuro', activar);
    modoTema.value = activar ? ThemeMode.dark : ThemeMode.light;
  }

  static bool get estaOscuro => modoTema.value == ThemeMode.dark;
}