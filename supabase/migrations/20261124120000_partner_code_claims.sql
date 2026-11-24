-- ════════════════════════════════════════════════════════════════════
-- Partner codes: promo codes a partner issued (AEG's SUB:ZERO codes on
-- AXS), which reps claim from the portal and a team admin approves.
--
-- Why: signup on the submerged team is open. Without this, anyone could
-- create an account and take another rep's AEG code as their Woosah promo
-- code, or a code that isn't on AEG's list at all.
--
-- Rules, enforced in the database:
--   • only codes on the team's list can be claimed
--   • one code per rep per batch, and a code belongs to one rep
--   • a rep's own claim is "pending" until a team admin approves it
--   • claiming never touches rank, points or pay (reps.rank, lifetime_points)
--   • signing up with a partner code as the Woosah promo code claims it the
--     same way (pending), and is refused if another rep already holds it
--
-- Seed: AEG's 44 SUB:ZERO codes for the submerged team. Reps whose Woosah
-- promo code already equals an AEG code (today Hope Davis FERALHOPE and
-- John Donelan NEBRASKA) are linked as approved.
--
-- Rollback: supabase/rollback/20261124_before_partner_code_claims.sql
-- NOT APPLIED. Apply only with the owner's explicit okay.
-- ════════════════════════════════════════════════════════════════════

create table if not exists private.partner_codes (
  id uuid primary key default gen_random_uuid(),
  tenant_slug text not null,
  batch text not null,
  code text not null,
  rep_id uuid references public.reps(id) on delete set null,
  status text not null default 'open',
  claimed_at timestamptz,
  approved_at timestamptz,
  approved_by uuid,
  created_at timestamptz not null default now(),
  constraint partner_codes_code_format check (code ~ '^[A-Z0-9]{2,32}$'),
  constraint partner_codes_status check (status in ('open', 'pending', 'approved')),
  constraint partner_codes_claim_consistent check ((status = 'open') = (rep_id is null)),
  constraint partner_codes_unique unique (tenant_slug, code)
);
create unique index if not exists partner_codes_one_per_rep
  on private.partner_codes (tenant_slug, batch, rep_id) where rep_id is not null;
revoke all on table private.partner_codes from public, anon, authenticated;
comment on table private.partner_codes is
  'Promo codes issued by a partner (e.g. AEG on AXS) that reps claim. Read and written only through RPCs.';

-- A removed rep frees their code.
create or replace function private.tg_partner_codes_tidy()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.code := upper(new.code);
  new.tenant_slug := private.norm_tenant(new.tenant_slug);
  if new.rep_id is null then
    new.status := 'open';
    new.claimed_at := null;
    new.approved_at := null;
    new.approved_by := null;
  end if;
  return new;
end $$;
drop trigger if exists trg_partner_codes_tidy on private.partner_codes;
create trigger trg_partner_codes_tidy before insert or update on private.partner_codes
  for each row execute function private.tg_partner_codes_tidy();

-- The caller's rep on a team, or null.
create or replace function private.my_rep_id(p_tenant text)
returns uuid language sql stable security definer set search_path = '' as $$
  select r.id from public.reps r
   where auth.uid() is not null and r.user_id = auth.uid()
     and private.tenant_row_matches(r.tenant_slug, private.norm_tenant(p_tenant))
   order by r.created_at asc limit 1;
$$;
revoke all on function private.my_rep_id(text) from public, anon, authenticated;

-- ── Signup with a partner code as the Woosah promo code ──
-- Before insert: refuse a partner code that another rep already holds.
create or replace function private.tg_reps_partner_code_check()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_code text := upper(coalesce(new.promo_code, ''));
begin
  if v_code = '' then return new; end if;
  if exists (select 1 from private.partner_codes pc
              where pc.tenant_slug = private.norm_tenant(new.tenant_slug)
                and pc.code = v_code and pc.rep_id is not null) then
    raise exception 'promo_code_claimed' using errcode = '23505',
      hint = 'That promo code already belongs to another rep.';
  end if;
  return new;
end $$;
revoke all on function private.tg_reps_partner_code_check() from public, anon, authenticated;
drop trigger if exists trg_zzzz_partner_code_check on public.reps;
create trigger trg_zzzz_partner_code_check before insert on public.reps
  for each row execute function private.tg_reps_partner_code_check();

-- After insert: claim it. Self-signup is pending; an admin adding a rep is approved.
create or replace function private.tg_reps_partner_code_claim()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_self boolean := private.is_self_service_write(new.tenant_slug);
begin
  update private.partner_codes pc
     set rep_id = new.id,
         status = case when v_self then 'pending' else 'approved' end,
         claimed_at = now(),
         approved_at = case when v_self then null else now() end,
         approved_by = case when v_self then null else auth.uid() end
   where pc.tenant_slug = private.norm_tenant(new.tenant_slug)
     and pc.code = upper(coalesce(new.promo_code, ''))
     and pc.rep_id is null
     and not exists (select 1 from private.partner_codes o
                      where o.tenant_slug = pc.tenant_slug and o.batch = pc.batch and o.rep_id = new.id);
  return null;
end $$;
revoke all on function private.tg_reps_partner_code_claim() from public, anon, authenticated;
drop trigger if exists trg_partner_code_claim on public.reps;
create trigger trg_partner_code_claim after insert on public.reps
  for each row execute function private.tg_reps_partner_code_claim();

-- The portal's "is this code free?" check also says no to a claimed partner code.
create or replace function private.promo_code_available(p_code text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare v_code text := upper(regexp_replace(coalesce(p_code,''), '[^A-Za-z0-9]', '', 'g'));
begin
  if length(v_code) < 3 or length(v_code) > 16 then return false; end if;
  if exists (
    select 1 from public.reps r
    where upper(r.promo_code) = v_code
      and (auth.uid() is null or r.user_id is distinct from auth.uid())
  ) then return false; end if;
  return not exists (
    select 1 from private.partner_codes pc
      join public.reps r on r.id = pc.rep_id
     where pc.code = v_code
       and (auth.uid() is null or r.user_id is distinct from auth.uid())
  );
end $$;

-- ── Rep RPCs ──
-- Batches on the caller's team, with the caller's own claim in each.
create or replace function public.partner_code_status(p_tenant text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v_slug text := private.norm_tenant(p_tenant); v_rep uuid;
begin
  if auth.uid() is null then return jsonb_build_object('batches', '[]'::jsonb); end if;
  v_rep := private.my_rep_id(v_slug);
  return jsonb_build_object('batches', coalesce((
    select jsonb_agg(jsonb_build_object(
             'batch', b.batch,
             'code', m.code,
             'status', m.status) order by b.batch)
      from (select distinct pc.batch from private.partner_codes pc where pc.tenant_slug = v_slug) b
      left join private.partner_codes m
        on m.tenant_slug = v_slug and m.batch = b.batch and v_rep is not null and m.rep_id = v_rep
  ), '[]'::jsonb));
end $$;
revoke all on function public.partner_code_status(text) from public, anon;
grant execute on function public.partner_code_status(text) to authenticated;

-- Claim a code. Returns {code, batch, status}; raises a short error word otherwise.
create or replace function public.claim_partner_code(p_tenant text, p_code text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare
  v_slug text := private.norm_tenant(p_tenant);
  v_code text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_rep uuid;
  v_row private.partner_codes%rowtype;
begin
  if auth.uid() is null then raise exception 'not_signed_in' using errcode = '42501'; end if;
  v_rep := private.my_rep_id(v_slug);
  if v_rep is null then raise exception 'no_profile' using errcode = '42501'; end if;
  select * into v_row from private.partner_codes pc
   where pc.tenant_slug = v_slug and pc.code = v_code for update;
  if not found then raise exception 'code_not_found' using errcode = 'P0002'; end if;
  if v_row.rep_id = v_rep then
    return jsonb_build_object('code', v_row.code, 'batch', v_row.batch, 'status', v_row.status);
  end if;
  if v_row.rep_id is not null
     or exists (select 1 from public.reps r where upper(r.promo_code) = v_code and r.id <> v_rep) then
    raise exception 'code_taken' using errcode = '23505';
  end if;
  if exists (select 1 from private.partner_codes o
              where o.tenant_slug = v_slug and o.batch = v_row.batch and o.rep_id = v_rep) then
    raise exception 'already_have_code' using errcode = '23505';
  end if;
  update private.partner_codes
     set rep_id = v_rep, status = 'pending', claimed_at = now()
   where id = v_row.id;
  return jsonb_build_object('code', v_row.code, 'batch', v_row.batch, 'status', 'pending');
end $$;
revoke all on function public.claim_partner_code(text, text) from public, anon;
grant execute on function public.claim_partner_code(text, text) to authenticated;

-- ── Admin RPCs ──
create or replace function public.admin_partner_codes(p_tenant text)
returns table (code text, batch text, status text, rep_id uuid, rep_name text,
               rep_email text, rep_promo_code text, claimed_at timestamptz, approved_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare v_slug text := private.norm_tenant(p_tenant);
begin
  if not public.is_tenant_admin(v_slug) then raise exception 'not_admin' using errcode = '42501'; end if;
  return query
    select pc.code, pc.batch, pc.status, pc.rep_id, r.name, r.email, r.promo_code, pc.claimed_at, pc.approved_at
      from private.partner_codes pc
      left join public.reps r on r.id = pc.rep_id
     where pc.tenant_slug = v_slug
     order by pc.batch, case pc.status when 'pending' then 0 when 'approved' then 1 else 2 end, pc.code;
end $$;
revoke all on function public.admin_partner_codes(text) from public, anon;
grant execute on function public.admin_partner_codes(text) to authenticated;

-- p_action: 'approve' (pending to approved) or 'release' (frees the code).
create or replace function public.admin_update_partner_code(p_tenant text, p_code text, p_action text)
returns jsonb language plpgsql volatile security definer set search_path = '' as $$
declare v_slug text := private.norm_tenant(p_tenant); v_code text := upper(coalesce(p_code, '')); v_n int;
begin
  if not public.is_tenant_admin(v_slug) then raise exception 'not_admin' using errcode = '42501'; end if;
  if p_action = 'approve' then
    update private.partner_codes
       set status = 'approved', approved_at = now(), approved_by = auth.uid()
     where tenant_slug = v_slug and code = v_code and status = 'pending';
  elsif p_action = 'release' then
    update private.partner_codes set rep_id = null
     where tenant_slug = v_slug and code = v_code and rep_id is not null;
  else
    raise exception 'bad_action' using errcode = '22023';
  end if;
  get diagnostics v_n = row_count;
  return jsonb_build_object('updated', v_n);
end $$;
revoke all on function public.admin_update_partner_code(text, text, text) from public, anon;
grant execute on function public.admin_update_partner_code(text, text, text) to authenticated;

-- ── Seed: AEG's SUB:ZERO codes for the submerged team ──
insert into private.partner_codes (tenant_slug, batch, code)
select 'submerged', 'SUB:ZERO', c from unnest(array[
  'ALLIJOY','ALYZARDD','ANGELB','CAITT','CAYLEE','CLAUDAZE','DIRTEBOIS','EMILEEFLOWS',
  'FERALHOPE','FERALLAY','GUINSWRLD','ICYLEX','JLO','JUL','KALIEN','KITANA','LENZZ',
  'LETSDANCE','LILTRIXZ','LIQUIDITY','MOONBABY','NADER','NEBRASKA','NOAHTRIP','NOODLE',
  'OHFLOW','PATANTO','RAVESISTAS','REALLIFE','RENXSSANCE','REVANVNT','SAVAGE4BASS',
  'SCOOTER','SIERRA','SMASH','SPACERADIO','SQUEAKZ','SUBMSCLE','TATTOOLOO','UPLIT',
  'WILDKARD','YAK','YISELIE','YOLYV'
]) as c
on conflict (tenant_slug, code) do nothing;

-- Reps whose Woosah code already equals an AEG code keep it, approved.
update private.partner_codes pc
   set rep_id = r.id, status = 'approved', claimed_at = now(), approved_at = now()
  from public.reps r
 where pc.tenant_slug = 'submerged' and pc.rep_id is null
   and upper(r.promo_code) = pc.code
   and private.tenant_row_matches(r.tenant_slug, 'submerged');
