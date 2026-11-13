-- Rollback for 20261113200000_team_eventbrite_payouts_rates.sql
-- Snapshot taken 2026-11-13 after tenant hardening (#13) was live.
-- That migration did not change any existing function or policy, so undoing it
-- means removing the functions it added. No rows are deleted: the new tables
-- (private.tenant_integrations), columns (tenant_settings.pay_rates,
-- payouts.paid_by), payouts rows and Vault secrets stay in place.
-- Redeploy the previous eventbrite-webhook version (v11, the file at commit
-- 59f3284) and the previous front end with it.
begin;
drop function if exists public.webhook_tenant_context(text);
drop function if exists public.rotate_eventbrite_webhook_key(text);
drop function if exists public.set_eventbrite_token(text, text);
drop function if exists public.eventbrite_connection(text);
drop function if exists private.ensure_tenant_integration(text);
drop function if exists public.mark_event_payouts_paid(uuid);
drop function if exists public.set_tenant_pay_rates(text, jsonb);
drop function if exists public.tenant_pay_rates(text);
drop function if exists private.tenant_pay_rate(text, text);
drop function if exists private.tenant_pay_rates(text);
-- Template tier perks before this migration (cosmetic):
update private.gamification_tiers set perk = 'Keep going. Hotshot unlocks $2.50/code' where tenant_slug = 'default' and name = 'Rising Star';
update private.gamification_tiers set perk = 'Reach Closer for $3/code + cash bonuses' where tenant_slug = 'default' and name = 'Hotshot';
update private.gamification_tiers set perk = 'Top tier: $3/code + VIP guest list' where tenant_slug = 'default' and name = 'Legend';
commit;
