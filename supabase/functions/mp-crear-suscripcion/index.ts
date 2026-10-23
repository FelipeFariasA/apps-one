// Crea una suscripción en Mercado Pago para el usuario conectado y devuelve el enlace de pago (init_point).
// Recibe { plan_id }. Si el usuario aún no tiene cuenta, se le crea una y queda como dueño.
// La suscripción se activa recién cuando el webhook informa el primer cobro aprobado.
// Archivo autocontenido para poder pegarlo tal cual en el editor de funciones del panel de Supabase.
import 'jsr:@supabase/functions-js/edge-runtime.d.ts';
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const responder = (status: number, body: Record<string, unknown>) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

const clienteAdmin = () =>
  createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });

// MP_ACCESS_TOKEN (de prueba o de producción) solo vive en los secretos de Supabase.
async function mp<T>(ruta: string, init: RequestInit = {}): Promise<T> {
  const res = await fetch('https://api.mercadopago.com' + ruta, {
    ...init,
    headers: { Authorization: 'Bearer ' + Deno.env.get('MP_ACCESS_TOKEN')!, 'Content-Type': 'application/json' },
  });
  const cuerpo = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`Mercado Pago ${res.status} en ${ruta}: ${JSON.stringify(cuerpo)}`);
  return cuerpo as T;
}

const PORTAL = Deno.env.get('PORTAL_URL') ?? 'http://localhost:3000';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return responder(405, { error: 'Método no permitido' });

  const comoUsuario = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } });
  const { data: { user } } = await comoUsuario.auth.getUser();
  if (!user?.email) return responder(401, { error: 'Necesitas iniciar sesión.' });

  let body: { plan_id?: number };
  try { body = await req.json(); } catch { return responder(400, { error: 'Datos inválidos.' }); }

  const admin = clienteAdmin();
  const { data: plan } = await admin.from('planes')
    .select('id, nombre, precio_clp, frecuencia_meses').eq('id', Number(body.plan_id)).eq('activo', true).maybeSingle();
  if (!plan) return responder(404, { error: 'Plan no encontrado.' });

  // Cuenta del usuario: la que ya tiene como dueño, o una nueva.
  let { data: miembro } = await admin.from('miembros')
    .select('cuenta_id').eq('user_id', user.id).eq('rol', 'dueno').limit(1).maybeSingle();
  if (!miembro) {
    const { data: cuenta, error } = await admin.from('cuentas')
      .insert({ nombre: user.user_metadata?.nombre ?? user.email, email_facturacion: user.email }).select('id').single();
    if (error) return responder(500, { error: 'No se pudo crear la cuenta: ' + error.message });
    await admin.from('miembros').insert({ cuenta_id: cuenta.id, user_id: user.id, rol: 'dueno' });
    miembro = { cuenta_id: cuenta.id };
  }

  const { data: viva } = await admin.from('suscripciones')
    .select('id, estado').eq('cuenta_id', miembro.cuenta_id).eq('plan_id', plan.id)
    .in('estado', ['pendiente', 'activa', 'pausada']).maybeSingle();
  if (viva && viva.estado !== 'pendiente') return responder(409, { error: 'Ya tienes este plan contratado.' });
  // Un intento anterior que nunca se pagó se descarta para abrir uno nuevo.
  if (viva) await admin.from('suscripciones').update({ estado: 'cancelada', actualizada_en: new Date().toISOString() }).eq('id', viva.id);

  const { data: sus, error: e1 } = await admin.from('suscripciones')
    .insert({ cuenta_id: miembro.cuenta_id, plan_id: plan.id }).select('id').single();
  if (e1) return responder(500, { error: 'No se pudo registrar la suscripción: ' + e1.message });

  try {
    const pre = await mp<{ id: string; init_point: string }>('/preapproval', {
      method: 'POST',
      body: JSON.stringify({
        reason: plan.nombre,
        external_reference: sus.id,
        payer_email: user.email,
        back_url: `${PORTAL}/?suscripcion=${sus.id}`,
        status: 'pending',
        auto_recurring: {
          frequency: plan.frecuencia_meses,
          frequency_type: 'months',
          transaction_amount: plan.precio_clp,
          currency_id: 'CLP',
        },
      }),
    });
    await admin.from('suscripciones').update({ mp_preapproval_id: pre.id }).eq('id', sus.id);
    return responder(200, { ok: true, suscripcion_id: sus.id, init_point: pre.init_point });
  } catch (e) {
    await admin.from('suscripciones').update({ estado: 'cancelada' }).eq('id', sus.id);
    return responder(502, { error: e instanceof Error ? e.message : 'Error con Mercado Pago' });
  }
});
