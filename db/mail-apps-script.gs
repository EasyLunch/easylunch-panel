/**
 * EASY LUNCH · Envío de mails del panel (informe de cierre de caja del Local Prosegur)
 *
 * Cómo instalarlo (una sola vez):
 *  1. Entrá a https://script.google.com con la cuenta de Google desde la que querés que salgan los mails
 *     (por ejemplo info@easylunch.com.ar) → "Nuevo proyecto".
 *  2. Borrá lo que aparece y pegá TODO este archivo. Cambiá la clave de SECRETO por una frase larga tuya.
 *  3. Guardá (Ctrl+S) → botón "Implementar" → "Nueva implementación" → tipo "Aplicación web".
 *     - Ejecutar como: Yo
 *     - Quién tiene acceso: Cualquier usuario
 *     → "Implementar" → autorizá los permisos → copiá la "URL de la aplicación web".
 *  4. En Vercel (proyecto easylunch-panel → Settings → Environment Variables) agregá:
 *     - MAIL_APPS_SCRIPT_URL = la URL que copiaste
 *     - MAIL_SECRET          = la misma clave que pusiste en SECRETO
 *     y volvé a desplegar (Deployments → … → Redeploy).
 */

const SECRETO = 'CAMBIA-ESTA-CLAVE-POR-UNA-FRASE-LARGA';

function doPost(e) {
  try {
    const d = JSON.parse((e && e.postData && e.postData.contents) || '{}');
    if (!SECRETO || SECRETO.indexOf('CAMBIA-ESTA-CLAVE') === 0) return salida({ ok: false, error: 'Falta cambiar la clave SECRETO en el script.' });
    if (d.secret !== SECRETO) return salida({ ok: false, error: 'Clave incorrecta.' });
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
  return salida({ ok: true, mensaje: 'Servicio de mails de Easy Lunch funcionando. Cuota restante hoy: ' + MailApp.getRemainingDailyQuota() });
}

function salida(o) {
  return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON);
}
