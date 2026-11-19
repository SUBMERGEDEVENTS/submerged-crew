-- Rollback for 20261119120000_ig_comment_picker.sql
-- Removes the functions and policies it added. The two tables are kept by default
-- so a saved draw record is never lost. Uncomment the last block only if you are
-- sure you want the draw history and the stored connection gone.
-- Redeploy the previous front end with it (the admin page hides the picker when
-- the igCommentPicker flag is false, so setting the flag to false is enough to hide it).
begin;
drop function if exists public.ig_connection_secret(text);
drop function if exists public.ig_update_token(text, text, timestamptz);
drop function if exists public.ig_save_connection(text, text, text, text, text, timestamptz, uuid);
drop function if exists public.ig_disconnect(text);
drop function if exists public.ig_connection_status(text);
drop policy if exists "Tenant admins read ig draws" on public.ig_comment_draws;
drop policy if exists "Tenant admins save ig draws" on public.ig_comment_draws;
drop trigger if exists trg_ig_draw_stamp on public.ig_comment_draws;
drop function if exists private.tg_ig_draw_stamp();
commit;

-- Destructive, optional. Deletes the Vault secret for every connection, then both tables.
-- begin;
-- delete from vault.secrets where id in (select secret_id from private.ig_connections);
-- drop table if exists private.ig_connections;
-- drop table if exists public.ig_comment_draws;
-- commit;
