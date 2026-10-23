-- Administración de Apps One: quién administra, qué puede tocar y los textos editables del portal.
-- Va en una migración aparte para poder correrla aunque la primera ya esté aplicada.

-- Administradores por correo, para que valga desde el primer ingreso. La lista se cambia solo con SQL.
create table public.administradores (
  email     text primary key check (email = lower(email)),
  creado_en timestamptz not null default now()
);
insert into public.administradores (email) values ('felipe.f.a@gmail.com');

-- ¿El usuario conectado es administrador? Exige que su correo esté confirmado, para que nadie
-- pueda registrarse con el correo de un administrador sin tener acceso a esa casilla.
create function public.es_admin()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
    from auth.users u
    join public.administradores a on a.email = lower(u.email)
    where u.id = (select auth.uid()) and u.email_confirmed_at is not null
  );
$$;
revoke execute on function public.es_admin() from public, anon;

-- Textos del portal que se editan sin tocar código (hero y pie).
create table public.ajustes (
  clave text primary key,
  valor text not null check (char_length(valor) <= 500)
);
insert into public.ajustes (clave, valor) values
  ('hero_overline', 'Catálogo de apps'),
  ('hero_titulo', 'Tu app, *lista* o a medida.'),
  ('hero_lead', 'Encuentra la app que necesitas, págala mes a mes con tarjeta de crédito o débito y empieza hoy. Sin costos ocultos.'),
  ('eslogan', 'Tu app, lista o a medida.');

alter table public.administradores enable row level security;
alter table public.ajustes          enable row level security;

create policy "admin ve administradores" on public.administradores
  for select to authenticated using ((select public.es_admin()));

create policy "textos visibles" on public.ajustes
  for select to anon, authenticated using (true);
create policy "admin edita textos" on public.ajustes
  for all to authenticated using ((select public.es_admin())) with check ((select public.es_admin()));

-- Catálogo: el administrador ve también lo oculto y puede crear, editar y borrar.
create policy "admin gestiona categorías" on public.categorias
  for all to authenticated using ((select public.es_admin())) with check ((select public.es_admin()));
create policy "admin gestiona aplicaciones" on public.aplicaciones
  for all to authenticated using ((select public.es_admin())) with check ((select public.es_admin()));
create policy "admin gestiona planes" on public.planes
  for all to authenticated using ((select public.es_admin())) with check ((select public.es_admin()));
create policy "admin gestiona contenido de planes" on public.plan_aplicaciones
  for all to authenticated using ((select public.es_admin())) with check ((select public.es_admin()));

-- Cotizaciones: el administrador las lee y cambia su estado.
create policy "admin ve cotizaciones" on public.cotizaciones
  for select to authenticated using ((select public.es_admin()));
create policy "admin actualiza cotizaciones" on public.cotizaciones
  for update to authenticated using ((select public.es_admin())) with check ((select public.es_admin()));

-- Clientes y cobros: solo lectura. Los cambios de estado los hace el webhook de Mercado Pago.
create policy "admin ve cuentas" on public.cuentas
  for select to authenticated using ((select public.es_admin()));
create policy "admin ve miembros" on public.miembros
  for select to authenticated using ((select public.es_admin()));
create policy "admin ve suscripciones" on public.suscripciones
  for select to authenticated using ((select public.es_admin()));
create policy "admin ve pagos" on public.pagos
  for select to authenticated using ((select public.es_admin()));
