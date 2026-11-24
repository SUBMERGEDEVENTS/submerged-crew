-- Undo 20261124120000_partner_code_claims.sql.
-- Removes the partner code triggers and RPCs, restores promo_code_available,
-- and drops private.partner_codes (claims and approvals are lost).
-- Reps and their Woosah promo codes are not changed.

drop trigger if exists trg_zzzz_partner_code_check on public.reps;
drop trigger if exists trg_partner_code_claim on public.reps;
drop function if exists private.tg_reps_partner_code_check();
drop function if exists private.tg_reps_partner_code_claim();
drop function if exists public.partner_code_status(text);
drop function if exists public.claim_partner_code(text, text);
drop function if exists public.admin_partner_codes(text);
drop function if exists public.admin_update_partner_code(text, text, text);

create or replace function private.promo_code_available(p_code text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare v_code text := upper(regexp_replace(coalesce(p_code,''), '[^A-Za-z0-9]', '', 'g'));
begin
  if length(v_code) < 3 or length(v_code) > 16 then return false; end if;
  return not exists (
    select 1 from public.reps r
    where upper(r.promo_code) = v_code
      and (auth.uid() is null or r.user_id is distinct from auth.uid())
  );
end $$;

drop table if exists private.partner_codes;
drop function if exists private.tg_partner_codes_tidy();
drop function if exists private.my_rep_id(text);
