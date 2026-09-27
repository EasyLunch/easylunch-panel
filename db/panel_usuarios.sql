-- =====================================================================
-- EASY LUNCH · Panel central — usuarios y permisos por tarjeta
-- Correr UNA vez en Supabase → SQL Editor → New query → Run.
-- Se puede volver a correr sin romper nada (no borra usuarios).
--
-- Seguridad:
--  * Las tablas tienen RLS activado y NINGUNA política: con la clave pública
--    (anon) no se pueden leer ni escribir directo. Solo a través de las
--    funciones panel_* de abajo.
--  * Las contraseñas se guardan encriptadas con bcrypt (pgcrypto).
--  * Cada login crea una sesión con un token al azar que vence a los 30 días.
--    Dar de baja a un usuario borra sus sesiones: queda afuera al instante.
--  * 5 contraseñas mal seguidas bloquean el usuario 10 minutos.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.panel_usuarios (
  id               uuid primary key default gen_random_uuid(),
  usuario          text not null unique,
  nombre           text not null default '',
  pass_hash        text not null,
  es_admin         boolean not null default false,
  activo           boolean not null default true,
  tarjetas         text[] not null default '{}',
  intentos         int not null default 0,
  bloqueado_hasta  timestamptz,
  ultimo_ingreso   timestamptz,
  creado           timestamptz not null default now(),
  actualizado      timestamptz not null default now()
);

create table if not exists public.panel_sesiones (
  token      text primary key,
  usuario_id uuid not null references public.panel_usuarios(id) on delete cascade,
  creada     timestamptz not null default now(),
  vence      timestamptz not null default now() + interval '30 days'
);

alter table public.panel_usuarios enable row level security;
alter table public.panel_sesiones enable row level security;
revoke all on public.panel_usuarios from anon, authenticated;
revoke all on public.panel_sesiones from anon, authenticated;

-- ---------- helpers internos ----------
create or replace function public.panel__info(u public.panel_usuarios)
returns json language sql stable as $$
  select json_build_object(
    'id', u.id, 'usuario', u.usuario, 'nombre', u.nombre,
    'admin', u.es_admin, 'activo', u.activo, 'tarjetas', u.tarjetas,
    'ultimo_ingreso', u.ultimo_ingreso, 'creado', u.creado);
$$;

create or replace function public.panel__nueva_sesion(p_id uuid)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare t text;
begin
  t := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.panel_sesiones(token, usuario_id) values (t, p_id);
  delete from public.panel_sesiones where vence < now();
  update public.panel_usuarios set ultimo_ingreso = now(), intentos = 0, bloqueado_hasta = null where id = p_id;
  return t;
end $$;

create or replace function public.panel__usuario_de(p_token text)
returns public.panel_usuarios language sql stable security definer set search_path = public as $$
  select u.* from public.panel_sesiones s
  join public.panel_usuarios u on u.id = s.usuario_id
  where s.token = p_token and s.vence > now() and u.activo
  limit 1;
$$;

create or replace function public.panel__admin_de(p_token text)
returns public.panel_usuarios language plpgsql stable security definer set search_path = public as $$
declare u public.panel_usuarios;
begin
  u := public.panel__usuario_de(p_token);
  if u.id is null then raise exception 'Sesión vencida. Volvé a ingresar.'; end if;
  if not u.es_admin then raise exception 'Solo un administrador puede hacer esto.'; end if;
  return u;
end $$;

-- ---------- públicas ----------
-- ¿Ya existe algún administrador? (si no, el panel muestra "crear primer administrador")
create or replace function public.panel_estado()
returns json language sql stable security definer set search_path = public as $$
  select json_build_object('hay_admin', exists(select 1 from public.panel_usuarios where es_admin and activo));
$$;

-- Solo funciona si todavía no hay ningún usuario cargado.
create or replace function public.panel_crear_primer_admin(p_usuario text, p_nombre text, p_pass text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare u public.panel_usuarios;
begin
  if exists(select 1 from public.panel_usuarios) then raise exception 'Ya hay usuarios creados. Ingresá con tu usuario.'; end if;
  if coalesce(trim(p_usuario), '') = '' then raise exception 'Falta el usuario.'; end if;
  if length(coalesce(p_pass, '')) < 6 then raise exception 'La contraseña tiene que tener al menos 6 caracteres.'; end if;
  insert into public.panel_usuarios(usuario, nombre, pass_hash, es_admin, activo)
  values (lower(trim(p_usuario)), trim(coalesce(p_nombre, '')), extensions.crypt(p_pass, extensions.gen_salt('bf')), true, true)
  returning * into u;
  return json_build_object('token', public.panel__nueva_sesion(u.id), 'usuario', public.panel__info(u));
end $$;

create or replace function public.panel_login(p_usuario text, p_pass text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare u public.panel_usuarios;
begin
  -- Los errores se devuelven como {"error": ...} (no con raise) para que quede guardado el intento fallido.
  select * into u from public.panel_usuarios where usuario = lower(trim(coalesce(p_usuario, '')));
  if u.id is null then return json_build_object('error', 'Usuario o contraseña incorrectos.'); end if;
  if u.bloqueado_hasta is not null and u.bloqueado_hasta > now() then
    return json_build_object('error', 'Demasiados intentos. Probá de nuevo en unos minutos.');
  end if;
  if u.pass_hash <> extensions.crypt(coalesce(p_pass, ''), u.pass_hash) then
    update public.panel_usuarios
       set intentos = intentos + 1,
           bloqueado_hasta = case when intentos + 1 >= 5 then now() + interval '10 minutes' else null end
     where id = u.id;
    return json_build_object('error', 'Usuario o contraseña incorrectos.');
  end if;
  if not u.activo then return json_build_object('error', 'Este usuario está dado de baja.'); end if;
  return json_build_object('token', public.panel__nueva_sesion(u.id), 'usuario', public.panel__info(u));
end $$;

create or replace function public.panel_sesion(p_token text)
returns json language plpgsql stable security definer set search_path = public as $$
declare u public.panel_usuarios;
begin
  u := public.panel__usuario_de(p_token);
  if u.id is null then return null; end if;
  return public.panel__info(u);
end $$;

create or replace function public.panel_logout(p_token text)
returns void language sql security definer set search_path = public as $$
  delete from public.panel_sesiones where token = p_token;
$$;

-- ---------- administrador ----------
create or replace function public.panel_admin_listar(p_token text)
returns json language plpgsql stable security definer set search_path = public as $$
begin
  perform public.panel__admin_de(p_token);
  return coalesce((select json_agg(public.panel__info(u) order by u.activo desc, u.nombre, u.usuario)
                   from public.panel_usuarios u), '[]'::json);
end $$;

-- p_id null = crear. p_pass vacío al editar = no cambia la contraseña.
create or replace function public.panel_admin_guardar(
  p_token text, p_id uuid, p_usuario text, p_nombre text, p_pass text,
  p_admin boolean, p_activo boolean, p_tarjetas text[])
returns json language plpgsql security definer set search_path = public, extensions as $$
declare
  yo public.panel_usuarios;
  u  public.panel_usuarios;
  v_usuario text := lower(trim(coalesce(p_usuario, '')));
begin
  yo := public.panel__admin_de(p_token);
  if v_usuario = '' then raise exception 'Falta el usuario.'; end if;
  if exists(select 1 from public.panel_usuarios where usuario = v_usuario and id is distinct from p_id) then
    raise exception 'Ya existe un usuario "%".', v_usuario;
  end if;

  if p_id is null then
    if length(coalesce(p_pass, '')) < 6 then raise exception 'La contraseña tiene que tener al menos 6 caracteres.'; end if;
    insert into public.panel_usuarios(usuario, nombre, pass_hash, es_admin, activo, tarjetas)
    values (v_usuario, trim(coalesce(p_nombre, '')), extensions.crypt(p_pass, extensions.gen_salt('bf')),
            coalesce(p_admin, false), coalesce(p_activo, true), coalesce(p_tarjetas, '{}'))
    returning * into u;
  else
    select * into u from public.panel_usuarios where id = p_id;
    if u.id is null then raise exception 'No encontré ese usuario.'; end if;
    if u.id = yo.id and (not coalesce(p_admin, true) or not coalesce(p_activo, true)) then
      raise exception 'No podés sacarte a vos mismo el rol de administrador ni darte de baja.';
    end if;
    if coalesce(p_pass, '') <> '' and length(p_pass) < 6 then
      raise exception 'La contraseña tiene que tener al menos 6 caracteres.';
    end if;
    update public.panel_usuarios set
      usuario    = v_usuario,
      nombre     = trim(coalesce(p_nombre, '')),
      pass_hash  = case when coalesce(p_pass, '') = '' then pass_hash else extensions.crypt(p_pass, extensions.gen_salt('bf')) end,
      es_admin   = coalesce(p_admin, es_admin),
      activo     = coalesce(p_activo, activo),
      tarjetas   = coalesce(p_tarjetas, tarjetas),
      intentos   = case when coalesce(p_pass, '') = '' then intentos else 0 end,
      bloqueado_hasta = case when coalesce(p_pass, '') = '' then bloqueado_hasta else null end,
      actualizado = now()
    where id = p_id
    returning * into u;
    -- baja o cambio de contraseña: se cierran sus sesiones abiertas (menos la mía)
    if not u.activo or coalesce(p_pass, '') <> '' then
      delete from public.panel_sesiones where usuario_id = u.id and token <> p_token;
    end if;
  end if;
  return public.panel__info(u);
end $$;

-- Borrar definitivamente (conviene más dar de baja).
create or replace function public.panel_admin_borrar(p_token text, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare yo public.panel_usuarios;
begin
  yo := public.panel__admin_de(p_token);
  if p_id = yo.id then raise exception 'No podés borrarte a vos mismo.'; end if;
  delete from public.panel_usuarios where id = p_id;
end $$;

-- Permisos: la clave pública solo puede ejecutar las funciones públicas.
revoke all on function public.panel__info(public.panel_usuarios) from public, anon, authenticated;
revoke all on function public.panel__nueva_sesion(uuid) from public, anon, authenticated;
revoke all on function public.panel__usuario_de(text) from public, anon, authenticated;
revoke all on function public.panel__admin_de(text) from public, anon, authenticated;
grant execute on function public.panel_estado() to anon, authenticated;
grant execute on function public.panel_crear_primer_admin(text, text, text) to anon, authenticated;
grant execute on function public.panel_login(text, text) to anon, authenticated;
grant execute on function public.panel_sesion(text) to anon, authenticated;
grant execute on function public.panel_logout(text) to anon, authenticated;
grant execute on function public.panel_admin_listar(text) to anon, authenticated;
grant execute on function public.panel_admin_guardar(text, uuid, text, text, text, boolean, boolean, text[]) to anon, authenticated;
grant execute on function public.panel_admin_borrar(text, uuid) to anon, authenticated;

notify pgrst, 'reload schema';
