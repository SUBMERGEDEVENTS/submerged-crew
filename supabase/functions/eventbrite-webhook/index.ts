// Supabase Edge Function — eventbrite-webhook
import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const EVENTBRITE_TOKEN = Deno.env.get('EVENTBRITE_TOKEN')!;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', {
      headers: {
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
      },
    });
  }

  if (req.method !== 'POST') {
    return new Response('Method not allowed', { status: 405 });
  }

  const sb = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY);

  try {
    if (!EVENTBRITE_TOKEN) {
      await logInbox(sb, { outcome: 'error', detail: 'EVENTBRITE_TOKEN not configured' });
      return json({ error: 'EVENTBRITE_TOKEN not configured' }, 500);
    }

    const body = await req.json();
    console.log('Webhook received:', JSON.stringify(body));

    const action = body.config?.action ?? null;
    const apiUrl = body.api_url;

    if (action !== 'order.placed' || !apiUrl) {
      await logInbox(sb, { action, outcome: 'ignored', detail: 'Not order.placed or missing api_url', payload: body });
      return json({ ignored: true, action }, 200);
    }

    const orderRes = await fetch(`${apiUrl}?expand=attendees`, {
      headers: { Authorization: `Bearer ${EVENTBRITE_TOKEN}` },
    });
    if (!orderRes.ok) {
      const text = await orderRes.text();
      await logInbox(sb, { action, outcome: 'order_fetch_failed', detail: `${orderRes.status} ${text}`, payload: body });
      return json({ error: 'Failed to fetch order', status: orderRes.status }, 502);
    }
    const order = await orderRes.json();
    const orderId = order.id ? String(order.id) : null;
    const eventbriteEventId = order.event_id ? String(order.event_id) : null;

    if (orderId) {
      const { data: existing } = await sb
        .from('sales')
        .select('id')
        .eq('order_id', orderId)
        .eq('source', 'eventbrite')
        .maybeSingle();
      if (existing) {
        await logInbox(sb, { action, order_id: orderId, event_id: eventbriteEventId, outcome: 'duplicate', payload: body });
        return json({ success: true, duplicate: true, order_id: orderId }, 200);
      }
    }

    let promoCode: string | null = null;

    // 1) Order-level discount / promotional_code (sometimes missing for 100% off)
    try {
      const discountRes = await fetch(
        `https://www.eventbriteapi.com/v3/orders/${order.id}/?expand=discount,promotional_code`,
        { headers: { Authorization: `Bearer ${EVENTBRITE_TOKEN}` } },
      );
      if (discountRes.ok) {
        const orderWithDiscount = await discountRes.json();
        console.log('Order discount expand:', JSON.stringify({
          discount: orderWithDiscount.discount,
          promotional_code: orderWithDiscount.promotional_code,
        }));
        if (orderWithDiscount.discount?.code) promoCode = String(orderWithDiscount.discount.code).toUpperCase();
        if (!promoCode && orderWithDiscount.promotional_code?.code) {
          promoCode = String(orderWithDiscount.promotional_code.code).toUpperCase();
        }
      }
    } catch (e) {
      console.log('Could not fetch order discount:', (e as Error).message);
    }

    if (!promoCode) {
      promoCode = order.promotional_code?.code?.toUpperCase() || order.discount?.code?.toUpperCase() || null;
    }

    // 2) Attendee-level promotional_code (Eventbrite's reliable path, incl. 100% off)
    if (!promoCode && order.attendees?.length > 0 && eventbriteEventId) {
      for (const attendee of order.attendees) {
        // Embedded on attendee if present
        if (attendee.promotional_code?.code) {
          promoCode = String(attendee.promotional_code.code).toUpperCase();
          console.log('Promo from attendee embed:', promoCode);
          break;
        }
        // Explicit attendee expand
        if (attendee.id) {
          try {
            const attRes = await fetch(
              `https://www.eventbriteapi.com/v3/events/${eventbriteEventId}/attendees/${attendee.id}/?expand=promotional_code`,
              { headers: { Authorization: `Bearer ${EVENTBRITE_TOKEN}` } },
            );
            if (attRes.ok) {
              const att = await attRes.json();
              console.log('Attendee promo expand:', JSON.stringify(att.promotional_code));
              if (att.promotional_code?.code) {
                promoCode = String(att.promotional_code.code).toUpperCase();
                break;
              }
            } else {
              console.log('Attendee promo fetch failed:', attRes.status, await attRes.text());
            }
          } catch (e) {
            console.log('Attendee promo fetch error:', (e as Error).message);
          }
        }
      }
    }

    // 3) Custom question answers fallback
    if (!promoCode && order.attendees?.length > 0) {
      for (const attendee of order.attendees) {
        for (const answer of attendee.answers || []) {
          const q = String(answer.question || '').toLowerCase();
          if ((q.includes('promo') || q.includes('code') || q.includes('referral')) && answer.answer) {
            promoCode = String(answer.answer).toUpperCase();
            break;
          }
        }
        if (promoCode) break;
      }
    }

    if (!promoCode) {
      await logInbox(sb, {
        action, order_id: orderId, event_id: eventbriteEventId,
        outcome: 'no_promo_code',
        detail: 'Order had no discount/promotional_code/attendee promo answer',
        payload: { webhook: body, order_id: orderId, event_id: eventbriteEventId },
      });
      return json({ skipped: true, reason: 'no_promo_code', order_id: orderId }, 200);
    }

    const ticketQuantity = order.attendees?.length || 1;

    const { data: rep, error: repError } = await sb
      .from('reps')
      .select('*')
      .eq('promo_code', promoCode)
      .maybeSingle();

    if (repError || !rep) {
      await logInbox(sb, {
        action, order_id: orderId, event_id: eventbriteEventId, promo_code: promoCode,
        outcome: 'rep_not_found',
        detail: repError?.message || `No rep with promo_code=${promoCode}`,
        payload: body,
      });
      return json({ skipped: true, reason: 'rep_not_found', promo_code: promoCode }, 200);
    }

    let { data: event } = await sb
      .from('events')
      .select('*')
      .eq('eventbrite_id', String(eventbriteEventId))
      .maybeSingle();

    if (!event) {
      const { data: activeEvents } = await sb
        .from('events')
        .select('*')
        .eq('status', 'active')
        .order('date', { ascending: true })
        .limit(1);
      event = activeEvents?.[0] || null;
    }

    if (!event) {
      await logInbox(sb, {
        action, order_id: orderId, event_id: eventbriteEventId, promo_code: promoCode,
        outcome: 'event_not_found',
        detail: `No events.eventbrite_id=${eventbriteEventId} and no active event fallback`,
        payload: body,
      });
      return json({ skipped: true, reason: 'event_not_found', eventbrite_event_id: eventbriteEventId }, 200);
    }

    const cashRate = getCashRate(rep.rank);
    const cashEarned = cashRate * ticketQuantity;
    const pointsEarned = 20 * ticketQuantity;

    let { data: repEvent } = await sb
      .from('rep_events')
      .select('*')
      .eq('rep_id', rep.id)
      .eq('event_id', event.id)
      .maybeSingle();

    if (!repEvent) {
      const { data: newRepEvent, error: joinErr } = await sb
        .from('rep_events')
        .insert({ rep_id: rep.id, event_id: event.id, codes_sold: 0, points_earned: 0, cash_earned: 0 })
        .select()
        .single();
      if (joinErr) {
        await logInbox(sb, { action, order_id: orderId, promo_code: promoCode, outcome: 'error', detail: joinErr.message });
        return json({ error: joinErr.message }, 500);
      }
      repEvent = newRepEvent;
    }

    const prevCodes = repEvent.codes_sold || 0;
    const newCodesSold = prevCodes + ticketQuantity;
    const newPointsEarned = (repEvent.points_earned || 0) + pointsEarned;
    const newCashEarned = parseFloat(String(repEvent.cash_earned || 0)) + cashEarned;

    await sb.from('rep_events').update({
      codes_sold: newCodesSold,
      points_earned: newPointsEarned,
      cash_earned: newCashEarned,
    }).eq('id', repEvent.id);

    let lifetimePts = (rep.lifetime_points || 0) + pointsEarned;
    await sb.from('reps').update({ lifetime_points: lifetimePts }).eq('id', rep.id);

    const { error: saleErr } = await sb.from('sales').insert({
      rep_id: rep.id,
      event_id: event.id,
      promo_code: promoCode,
      order_id: orderId,
      ticket_quantity: ticketQuantity,
      points_awarded: pointsEarned,
      cash_awarded: cashEarned,
      source: 'eventbrite',
    });
    if (saleErr) {
      if (String(saleErr.message || '').toLowerCase().includes('duplicate')) {
        await logInbox(sb, { action, order_id: orderId, promo_code: promoCode, outcome: 'duplicate' });
        return json({ success: true, duplicate: true, order_id: orderId }, 200);
      }
      await logInbox(sb, { action, order_id: orderId, promo_code: promoCode, outcome: 'error', detail: saleErr.message });
      return json({ error: saleErr.message }, 500);
    }

    await sb.from('points_log').insert({
      rep_id: rep.id,
      event_id: event.id,
      type: 'sale',
      points: pointsEarned,
      cash: cashEarned,
      description: `${ticketQuantity} ticket(s) sold via code ${promoCode}`,
    });

    await sb.from('events').update({
      tickets_sold: (event.tickets_sold || 0) + ticketQuantity,
    }).eq('id', event.id);

    const milestones = [
      { threshold: 10, points: 200, cash: 0, type: 'milestone_10', label: '10-code milestone bonus!' },
      { threshold: 25, points: 500, cash: 10, type: 'milestone_25', label: '25-code milestone — $10 bonus!' },
      { threshold: 50, points: 1000, cash: 25, type: 'milestone_50', label: '50-code milestone — $25 bonus!' },
    ];

    // Award every milestone this order crosses (one order can cross 25 AND 50).
    // Cash accumulates instead of overwriting, and each milestone is idempotent
    // per rep+event: skip it if a points_log row of that type already exists.
    let runningCash = newCashEarned;
    for (const m of milestones) {
      if (prevCodes < m.threshold && newCodesSold >= m.threshold) {
        const { data: already } = await sb
          .from('points_log')
          .select('id')
          .eq('rep_id', rep.id)
          .eq('event_id', event.id)
          .eq('type', m.type)
          .limit(1);
        if (already && already.length > 0) continue;
        const { error: msErr } = await sb.from('points_log').insert({
          rep_id: rep.id, event_id: event.id, type: m.type, points: m.points, cash: m.cash, description: m.label,
        });
        if (msErr) {
          console.error(`milestone ${m.type} insert failed:`, msErr.message);
          continue;
        }
        lifetimePts += m.points;
        runningCash += m.cash;
      }
    }
    if (lifetimePts !== (rep.lifetime_points || 0) + pointsEarned) {
      await sb.from('reps').update({ lifetime_points: lifetimePts }).eq('id', rep.id);
    }
    if (runningCash !== newCashEarned) {
      await sb.from('rep_events').update({ cash_earned: runningCash }).eq('id', repEvent.id);
    }

    await logInbox(sb, {
      action, order_id: orderId, event_id: eventbriteEventId, promo_code: promoCode,
      outcome: 'credited',
      detail: `${rep.name}: ${pointsEarned}pts + $${cashEarned}`,
      payload: { order_id: orderId, rep: rep.name, tickets: ticketQuantity },
    });

    return json({
      success: true,
      rep: rep.name,
      code: promoCode,
      points: pointsEarned,
      cash: cashEarned,
      total_codes: newCodesSold,
    }, 200);
  } catch (err) {
    console.error('Webhook error:', err);
    try {
      await logInbox(sb, { outcome: 'error', detail: (err as Error).message });
    } catch (_) { /* ignore */ }
    return json({ error: (err as Error).message }, 500);
  }
});

function getCashRate(rank: string): number {
  switch (rank) {
    case 'Legend':
    case 'Closer':
      return 3.0;
    case 'Hotshot':
      return 2.5;
    default:
      return 2.0;
  }
}

function json(data: unknown, status: number) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

async function logInbox(sb: SupabaseClient, row: {
  action?: string | null;
  order_id?: string | null;
  event_id?: string | null;
  promo_code?: string | null;
  outcome: string;
  detail?: string | null;
  payload?: unknown;
}) {
  const { error } = await sb.from('webhook_inbox').insert({
    source: 'eventbrite',
    action: row.action ?? null,
    order_id: row.order_id ?? null,
    event_id: row.event_id ?? null,
    promo_code: row.promo_code ?? null,
    outcome: row.outcome,
    detail: row.detail ?? null,
    payload: row.payload ?? null,
  });
  if (error) console.error('webhook_inbox insert failed:', error.message);
}
