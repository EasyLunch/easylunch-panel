// Vercel Serverless Function · /api/gourmet-usuario
// Crea usuarios de clientes Gourmet, cambia contraseñas y elimina usuarios.
// Solo la puede usar un administrador logueado en gourmet-admin.html.
//
// Variables de entorno necesarias en Vercel (Settings → Environment Variables):
//   SUPABASE_URL               = https://TU-PROYECTO.supabase.co
//   SUPABASE_SERVICE_ROLE_KEY  = (Supabase → Project Settings → API → service_role)  ¡NUNCA en el HTML!

export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'Método no permitido' });

  const URL = process.env.SUPABASE_URL;
  const SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!URL || !SERVICE) {
    return res.status(500).json({ error: 'Faltan SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY en las variables de Vercel' });
  }

  const token = String(req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!token) return res.status(401).json({ error: 'Sesión requerida' });

  const H = { apikey: SERVICE, Authorization: `Bearer ${SERVICE}`, 'Content-Type': 'application/json' };

  try {
    // 1) ¿Quién llama?
    const meRes = await fetch(`${URL}/auth/v1/user`, { headers: { apikey: SERVICE, Authorization: `Bearer ${token}` } });
    if (!meRes.ok) return res.status(401).json({ error: 'Sesión vencida. Volvé a ingresar.' });
    const me = await meRes.json();

    // 2) ¿Es administrador?
    const rolRes = await fetch(`${URL}/rest/v1/gourmet_usuarios?id=eq.${me.id}&select=rol,activo`, { headers: H });
    const rol = (await rolRes.json())[0];
    if (!rol || rol.rol !== 'admin' || !rol.activo) return res.status(403).json({ error: 'Solo administradores' });

    const body = typeof req.body === 'string' ? JSON.parse(req.body || '{}') : (req.body || {});
    const { accion } = body;

    // ---------- CREAR ----------
    if (accion === 'crear') {
      const email = String(body.email || '').trim().toLowerCase();
      const password = String(body.password || '');
      const nombre = String(body.nombre || '').trim();
      const r = body.rol === 'admin' ? 'admin' : 'cliente';
      if (!email || !email.includes('@')) return res.status(400).json({ error: 'Email inválido' });
      if (password.length < 8) return res.status(400).json({ error: 'La contraseña debe tener al menos 8 caracteres' });
      if (r === 'cliente' && !body.empresa_id) return res.status(400).json({ error: 'Elegí la empresa del usuario' });

      const cr = await fetch(`${URL}/auth/v1/admin/users`, {
        method: 'POST', headers: H,
        body: JSON.stringify({ email, password, email_confirm: true, user_metadata: { nombre, app: 'gourmet' } })
      });
      const cu = await cr.json();
      if (!cr.ok) {
        const msg = cu.msg || cu.message || cu.error_description || cu.error || 'No se pudo crear el usuario';
        return res.status(400).json({ error: /already|registered|exists/i.test(msg) ? 'Ese email ya tiene un usuario' : msg });
      }
      const uid = cu.id || cu.user?.id;

      const ins = await fetch(`${URL}/rest/v1/gourmet_usuarios`, {
        method: 'POST', headers: { ...H, Prefer: 'return=minimal' },
        body: JSON.stringify({ id: uid, email, nombre, rol: r, empresa_id: body.empresa_id || null, telefono: body.telefono || null })
      });
      if (!ins.ok) {
        await fetch(`${URL}/auth/v1/admin/users/${uid}`, { method: 'DELETE', headers: H });
        return res.status(400).json({ error: 'No se pudo guardar el perfil: ' + (await ins.text()) });
      }
      return res.status(200).json({ ok: true, id: uid });
    }

    // ---------- CAMBIAR CONTRASEÑA ----------
    if (accion === 'clave') {
      if (!body.id || String(body.password || '').length < 8) return res.status(400).json({ error: 'Contraseña de al menos 8 caracteres' });
      const r = await fetch(`${URL}/auth/v1/admin/users/${body.id}`, {
        method: 'PUT', headers: H, body: JSON.stringify({ password: body.password })
      });
      if (!r.ok) return res.status(400).json({ error: 'No se pudo cambiar la contraseña' });
      return res.status(200).json({ ok: true });
    }

    // ---------- ELIMINAR ----------
    if (accion === 'eliminar') {
      if (!body.id) return res.status(400).json({ error: 'Falta id' });
      if (body.id === me.id) return res.status(400).json({ error: 'No podés eliminar tu propio usuario' });
      // los pedidos quedan (usuario_id pasa a null)
      const r = await fetch(`${URL}/auth/v1/admin/users/${body.id}`, { method: 'DELETE', headers: H });
      if (!r.ok) return res.status(400).json({ error: 'No se pudo eliminar' });
      return res.status(200).json({ ok: true });
    }

    return res.status(400).json({ error: 'Acción desconocida' });
  } catch (e) {
    return res.status(500).json({ error: 'Error del servidor: ' + e.message });
  }
}
