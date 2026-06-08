const { onSchedule } = require("firebase-functions/v2/scheduler");
const admin = require("firebase-admin");

admin.initializeApp();

// Se ejecuta cada hora para revisar quién lleva 24h sin entrar
// Usamos la nueva sintaxis 'onSchedule' de la v2
exports.verificarInactividad = onSchedule("every 1 hours", async (event) => {
    const ahora = admin.firestore.Timestamp.now();
    // Calculamos el tiempo de hace 24 horas
    const hace24Horas = new Date(ahora.toDate().getTime() - (24 * 60 * 60 * 1000));

    console.log("Iniciando revisión de inactividad...");

    // Buscamos usuarios inactivos
    const usuariosInactivos = await admin.firestore().collection('usuarios')
        .where('ultima_actividad', '<=', hace24Horas)
        .where('notificacion_inactividad_enviada', '==', false)
        .get();

    if (usuariosInactivos.empty) {
        console.log("No hay usuarios inactivos para notificar.");
        return null;
    }

    const promesas = [];

    usuariosInactivos.forEach(doc => {
        const data = doc.data();
        const token = data.fcm_token;
        const nombreNegocio = data.nombre_negocio || "tu negocio";

        if (token) {
            const mensaje = {
                notification: {
                    title: '¡Te extrañamos!',
                    body: `Hola ${nombreNegocio}, tu negocio te espera 🚀`,
                },
                data: {
                    tipo: 'inactividad' 
                },
                token: token,
                android: {
                    priority: 'high',
                    notification: {
                        channelId: 'inactividad', 
                    }
                }
            };

            // Enviamos el mensaje y marcamos al usuario
            promesas.push(admin.messaging().send(mensaje));
            promesas.push(doc.ref.update({ notificacion_inactividad_enviada: true }));
        }
    });

    await Promise.all(promesas);
    console.log(`Se enviaron ${promesas.length / 2} notificaciones.`);
    return null;
});