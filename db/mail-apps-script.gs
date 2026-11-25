/**
 * EASY LUNCH · Envío de mails del panel (informe de cierre de caja del Local Prosegur)
 * Proyecto de Apps Script en la cuenta info@easylunch.com.ar (los mails salen desde esa cuenta).
 *
 * Instalación (una sola vez):
 *  1. https://script.google.com con la cuenta que manda los mails → "Nuevo proyecto" → pegar TODO este archivo.
 *  2. "Implementar" → "Nueva implementación" → tipo "Aplicación web"
 *     (Ejecutar como: Yo · Quién tiene acceso: Cualquier usuario) → autorizar → copiar la URL.
 *  3. Clave compartida (la misma en los dos lados):
 *     - Acá: ⚙ "Configuración del proyecto" → "Propiedades de la secuencia de comandos" → agregar
 *       propiedad MAIL_SECRET con una frase larga.
 *     - En Vercel (easylunch-panel → Settings → Environment Variables): MAIL_SECRET con la misma frase,
 *       y MAIL_APPS_SCRIPT_URL con la URL del paso 2. Después: Deployments → … → Redeploy.
 *  Cambiar la clave más adelante no requiere volver a implementar el script.
 */

function doPost(e) {
  try {
    const secreto = PropertiesService.getScriptProperties().getProperty('MAIL_SECRET');
    if (!secreto || secreto.length < 12) return salida({ ok: false, error: 'Falta configurar la propiedad MAIL_SECRET del script (mínimo 12 caracteres).' });
    const d = JSON.parse((e && e.postData && e.postData.contents) || '{}');
    if (d.secret !== secreto) return salida({ ok: false, error: 'Clave incorrecta.' });
    const destinos = (Array.isArray(d.to) ? d.to : String(d.to || '').split(','))
      .map(function (x) { return String(x).trim(); })
      .filter(function (x) { return /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(x); });
    if (!destinos.length) return salida({ ok: false, error: 'Sin destinatarios válidos.' });
    if (destinos.length > 10) return salida({ ok: false, error: 'Máximo 10 destinatarios.' });
    MailApp.sendEmail({
      to: destinos.join(','),
      subject: String(d.subject || 'Easy Lunch').slice(0, 250),
      htmlBody: String(d.html || ''),
      body: String(d.text || ''),
      name: String(d.nombre || 'Easy Lunch')
    });
    return salida({ ok: true, enviados: destinos.length });
  } catch (err) {
    return salida({ ok: false, error: String(err && err.message || err) });
  }
}

function doGet() {
  const conClave = !!PropertiesService.getScriptProperties().getProperty('MAIL_SECRET');
  return salida({ ok: true, mensaje: 'Servicio de mails de Easy Lunch funcionando.', clave_configurada: conClave });
}

/** Correr una vez desde el editor (▶ Ejecutar) para autorizar el envío de mails y probar. */
function probarEnvio() {
  MailApp.sendEmail(Session.getActiveUser().getEmail() || 'info@easylunch.com.ar', 'Prueba · mails del panel de Easy Lunch', 'Si te llegó este mail, el envío funciona.');
}

function salida(o) {
  return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON);
}
