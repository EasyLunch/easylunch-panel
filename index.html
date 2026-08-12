-- ============================================================================
-- Easy Lunch — Carga de Costos y Gastos por Fotos
-- Migración: correr una sola vez en Supabase → SQL Editor
-- Crea: conversiones de unidades de compra, compras, ítems e historial de precios.
-- Idempotente: usa IF NOT EXISTS. No toca ninguna tabla existente.
-- ============================================================================

-- Necesario para gen_random_uuid()
create extension if not exists pgcrypto;

-- ── 1) Conversiones: cómo pasar de la unidad de COMPRA a la unidad BASE del insumo
--     Ej.: papa se guarda por 'kg' (insumos.unidad='kg'); se compra por 'bolsa'.
--     factor = cuántas unidades base entran en 1 unidad de compra (1 bolsa = 20 kg → factor 20).
create table if not exists insumo_unidades_compra (
  id            uuid primary key default gen_random_uuid(),
  insumo_id     text not null,               -- id del insumo (mismo valor que insumos.id)
  nombre_compra text not null,               -- 'bolsa', 'cajón', 'atado', 'caja x12', 'unidad'...
  factor        numeric not null check (factor > 0), -- unidades base por 1 unidad de compra
  nota          text,
  activo        boolean not null default true,
  created_at    timestamptz not null default now(),
  unique (insumo_id, nombre_compra)
);
comment on table insumo_unidades_compra is 'Conversión unidad de compra -> unidad base del insumo (para costear por kg/lt/unidad).';

-- ── 2) Compras (cabecera de cada comprobante cargado)
create table if not exists compras (
  id              uuid primary key default gen_random_uuid(),
  proveedor       text,
  cuit            text,
  tipo            text,                        -- 'Factura A', 'Factura B', 'Ticket', 'Remito'...
  punto_venta     text,
  nro_comprobante text,
  fecha           date,
  cond_iva        text,                        -- 'Responsable Inscripto', 'No fiscal'...
  neto            numeric default 0,
  iva             numeric default 0,
  total           numeric default 0,
  cae             text,
  origen          text default 'foto',         -- 'foto' | 'manual'
  foto_url        text,
  notas           text,
  creado_por      text,
  created_at      timestamptz not null default now()
);
create index if not exists idx_compras_fecha on compras (fecha);

-- ── 3) Ítems de cada compra (renglones)
create table if not exists compra_items (
  id                uuid primary key default gen_random_uuid(),
  compra_id         uuid not null references compras(id) on delete cascade,
  descripcion       text,                      -- texto tal cual del comprobante
  insumo_id         text,                      -- insumo vinculado (puede quedar null)
  cantidad          numeric,
  unidad            text,                      -- unidad de compra ('kg','unidad','bolsa'...)
  precio_unit       numeric,                   -- precio unitario s/IVA por unidad de compra
  iva_pct           numeric default 0,
  subtotal_neto     numeric,
  iva               numeric default 0,
  subtotal_total    numeric,
  factor_conversion numeric,                   -- factor usado a unidad base (null si no aplica)
  costo_base_aplicado numeric,                 -- costo s/IVA por unidad base que se aplicó al insumo
  actualizo_costo   boolean not null default false,
  created_at        timestamptz not null default now()
);
create index if not exists idx_compra_items_compra on compra_items (compra_id);
create index if not exists idx_compra_items_insumo on compra_items (insumo_id);

-- ── 4) Historial de precios de insumos (para trazabilidad y alertas)
create table if not exists insumo_precio_historial (
  id              uuid primary key default gen_random_uuid(),
  insumo_id       text not null,
  nombre_insumo   text,
  precio_anterior numeric,
  precio_nuevo    numeric,
  pct_cambio      numeric,
  compra_id       uuid references compras(id) on delete set null,
  origen          text default 'factura',
  usuario         text,
  fecha           timestamptz not null default now()
);
create index if not exists idx_hist_insumo on insumo_precio_historial (insumo_id);
create index if not exists idx_hist_fecha on insumo_precio_historial (fecha);

-- ── 5) Permisos (mismo modelo que el resto de la app: acceso vía anon key)
do $$
declare t text;
begin
  foreach t in array array['insumo_unidades_compra','compras','compra_items','insumo_precio_historial']
  loop
    execute format('alter table %I enable row level security;', t);
    execute format('drop policy if exists "el_public_all" on %I;', t);
    execute format('create policy "el_public_all" on %I for all to anon, authenticated using (true) with check (true);', t);
    execute format('grant all on %I to anon, authenticated;', t);
  end loop;
end $$;

-- Listo. Si no hubo errores, las 4 tablas quedaron creadas y accesibles.
