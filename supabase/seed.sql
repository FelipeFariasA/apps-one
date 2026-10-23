-- Catálogo inicial de Apps One. Ajusta nombres, precios y URLs antes de correrlo.
-- Se puede correr más de una vez: no duplica categorías ni apps.

insert into public.categorias (id, nombre, orden) values
  ('gestion', 'Gestión', 1),
  ('finanzas', 'Finanzas', 2),
  ('analitica', 'Analítica', 3)
on conflict (id) do update set nombre = excluded.nombre, orden = excluded.orden;

insert into public.aplicaciones (id, categoria_id, nombre, descripcion, url) values
  ('vannucci', 'gestion', 'Portal Vannucci', 'Producción del taller, orfebres, trabajos en revisión y costos.', 'https://vannucci-app.vercel.app')
on conflict (id) do update set
  categoria_id = excluded.categoria_id, nombre = excluded.nombre, descripcion = excluded.descripcion, url = excluded.url;

-- Planes: se crean solo si aún no existe uno con ese nombre.
insert into public.planes (nombre, precio_clp, frecuencia_meses)
select v.nombre, v.precio_clp, v.frecuencia_meses
from (values ('Vannucci mensual', 19990, 1::smallint), ('Vannucci anual', 199900, 12::smallint)) as v (nombre, precio_clp, frecuencia_meses)
where not exists (select 1 from public.planes p where p.nombre = v.nombre);

insert into public.plan_aplicaciones (plan_id, aplicacion_id)
select p.id, 'vannucci' from public.planes p where p.nombre in ('Vannucci mensual', 'Vannucci anual')
on conflict do nothing;
