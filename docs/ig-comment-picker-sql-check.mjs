// Runs the Round 2 migration and its rollback in an in-memory Postgres (PGlite) with stubbed Supabase auth and Vault.
// It never touches the real project. Usage: npm i --no-save @electric-sql/pglite && node docs/ig-comment-picker-sql-check.mjs
import { PGlite } from '@electric-sql/pglite';
import fs from 'fs';
const db = new PGlite();
const root = new URL('../supabase/', import.meta.url).pathname;
await db.exec(`
create role anon nologin; create role authenticated nologin; create role service_role nologin bypassrls;
create schema auth; create schema private; create schema vault; create schema extensions;
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.sub', true),'')::uuid $$;
create function auth.role() returns text language sql stable as $$ select coalesce(nullif(current_setting('request.jwt.role', true),''),'service_role') $$;
create table vault.secrets (id uuid primary key default gen_random_uuid(), name text, description text, secret text);
create function vault.create_secret(s text, n text default null, d text default '') returns uuid language plpgsql as $$ declare i uuid; begin insert into vault.secrets(name,description,secret) values(n,d,s) returning id into i; return i; end $$;
create function vault.update_secret(i uuid, s text) returns void language sql as $$ update vault.secrets set secret=s where id=i $$;
create view vault.decrypted_secrets as select id, name, secret as decrypted_secret from vault.secrets;
create table public.admins (user_id uuid, tenant_slug text);
grant usage on schema public, private to authenticated, service_role;
create function private.tenant_row_matches(p_row_slug text, p_tenant text) returns boolean language sql immutable as $$ select coalesce(nullif(lower(btrim(p_row_slug)),''),'submerged') = coalesce(nullif(lower(btrim(p_tenant)),''),'submerged') $$;
`);
// real helper definitions from the repo
const m = fs.readFileSync(root+'migrations/20261113190000_tenant_hardening.sql','utf8');
await db.exec(m.match(/create or replace function private\.norm_tenant[\s\S]*?\$\$;/)[0]);
const iso = fs.readFileSync(root+'migrations/20261113171729_tenant_isolation_rls_and_stamping.sql','utf8');
await db.exec(iso.match(/create or replace function public\.is_tenant_admin[\s\S]*?\$\$;/)[0]);
await db.exec(`grant execute on all functions in schema private to authenticated, service_role; grant execute on function public.is_tenant_admin(text) to authenticated, service_role;`);
await db.exec(fs.readFileSync(root+'migrations/20261119120000_ig_comment_picker.sql','utf8'));
const A='00000000-0000-0000-0000-00000000000a', B='00000000-0000-0000-0000-00000000000b', C='00000000-0000-0000-0000-00000000000c';
await db.exec(`insert into public.admins values ('${A}','submerged'), ('${B}','acme-demo');`);
const out=[]; const ok=(n,c,x='')=>out.push([c?'PASS':'FAIL',n,x]);
async function as(role, sub, sql, params){ await db.exec(`set role ${role}; select set_config('request.jwt.sub','${sub||''}',false), set_config('request.jwt.role','${role}',false);`); try { return await db.query(sql, params); } finally { await db.exec('reset role'); } }
async function fails(role, sub, sql, params){ try { await as(role,sub,sql,params); return false; } catch(e){ return e.message; } }

// draws
let r = await as('authenticated',A,`insert into public.ig_comment_draws (tenant_slug, post_url, rules, entrant_count, eligible_count, winners, drawn_by) values ('submerged','https://www.instagram.com/p/X/','{"a":1}',10,8,'[{"username":"u"}]','${B}') returning drawn_by, tenant_slug`);
ok('admin of submerged can save a draw; drawn_by is forced to the caller', r.rows[0].drawn_by===A && r.rows[0].tenant_slug==='submerged', JSON.stringify(r.rows[0]));
r = await as('authenticated',A,`select count(*)::int n from public.ig_comment_draws`); ok('admin reads own tenant draws', r.rows[0].n===1);
r = await as('authenticated',B,`select count(*)::int n from public.ig_comment_draws`); ok('admin of another tenant sees none', r.rows[0].n===0);
ok('admin of another tenant cannot insert into submerged', !!(await fails('authenticated',B,`insert into public.ig_comment_draws (tenant_slug, post_url, entrant_count, eligible_count) values ('submerged','u',1,1)`)));
ok('non-admin cannot insert', !!(await fails('authenticated',C,`insert into public.ig_comment_draws (tenant_slug, post_url, entrant_count, eligible_count) values ('submerged','u',1,1)`)));
r = await as('authenticated',C,`select count(*)::int n from public.ig_comment_draws`); ok('non-admin reads none', r.rows[0].n===0);
ok('anon has no access', !!(await fails('anon','',`select 1 from public.ig_comment_draws`)));
ok('draws cannot be updated', !!(await fails('authenticated',A,`update public.ig_comment_draws set post_url='z'`)));
ok('draws cannot be deleted', !!(await fails('authenticated',A,`delete from public.ig_comment_draws`)));
ok('bad tenant slug rejected', !!(await fails('authenticated',A,`insert into public.ig_comment_draws (tenant_slug, post_url, entrant_count, eligible_count) values ('Bad Slug!','u',1,1)`)));
r = await as('authenticated',A,`insert into public.ig_comment_draws (tenant_slug, post_url, entrant_count, eligible_count) values ('','u',1,1) returning tenant_slug`); ok('blank tenant normalises to submerged', r.rows[0].tenant_slug==='submerged');

// connection functions
const TOK='IGAAxxxxxxxxxxxxxxxxxxxxxxxxxxxx';
ok('authenticated cannot call ig_save_connection', !!(await fails('authenticated',A,`select public.ig_save_connection('submerged','${TOK}','graph.instagram.com','1','u',null,null)`)));
ok('authenticated cannot read the token', !!(await fails('authenticated',A,`select public.ig_connection_secret('submerged')`)));
ok('authenticated cannot read private table', !!(await fails('authenticated',A,`select * from private.ig_connections`)));
await as('service_role','',`select public.ig_save_connection('submerged','${TOK}','graph.instagram.com','123','submerged_events', now()+interval '60 days', '${A}')`);
r = await as('service_role','',`select public.ig_connection_secret('submerged') j`); ok('service role reads the token back', r.rows[0].j.token===TOK && r.rows[0].j.ig_user_id==='123');
r = await as('authenticated',A,`select public.ig_connection_status('submerged') j`); ok('admin status has no token field', r.rows[0].j.connected===true && r.rows[0].j.username==='submerged_events' && !JSON.stringify(r.rows[0].j).includes('IGAA') && !('token' in r.rows[0].j));
ok('other tenant admin cannot read status', !!(await fails('authenticated',B,`select public.ig_connection_status('submerged')`)));
ok('non-admin cannot read status', !!(await fails('authenticated',C,`select public.ig_connection_status('submerged')`)));
await as('service_role','',`select public.ig_update_token('submerged','IGAAnewnewnewnewnewnewnewnewnew', now()+interval '60 days')`);
r = await as('service_role','',`select public.ig_connection_secret('submerged') j`); ok('refresh replaces token in place (one vault row)', r.rows[0].j.token.startsWith('IGAAnew') && (await db.query('select count(*)::int n from vault.secrets')).rows[0].n===1);
ok('other tenant admin cannot disconnect', !!(await fails('authenticated',B,`select public.ig_disconnect('submerged')`)));
await as('authenticated',A,`select public.ig_disconnect('submerged')`);
r = await as('authenticated',A,`select public.ig_connection_status('submerged') j`); ok('disconnect removes connection and the vault secret', r.rows[0].j.connected===false && (await db.query('select count(*)::int n from vault.secrets')).rows[0].n===0);
ok('short token rejected', !!(await fails('service_role','',`select public.ig_save_connection('submerged','short','graph.instagram.com','1','u',null,null)`)));
ok('bad api host rejected', !!(await fails('service_role','',`select public.ig_save_connection('submerged','${TOK}','evil.example','1','u',null,null)`)));

// rollback runs clean
await db.exec(fs.readFileSync(root+'rollback/20261119_before_ig_comment_picker.sql','utf8').split('-- Destructive')[0]);
r = await db.query(`select count(*)::int n from pg_proc where proname like 'ig\\_%'`); ok('rollback removes the functions', r.rows[0].n===0);
r = await db.query(`select count(*)::int n from public.ig_comment_draws`); ok('rollback keeps the draw history', r.rows[0].n===2);
console.log(out.map(x=>x.join(' | ')).join('\n')); console.log(out.filter(x=>x[0]==='FAIL').length+' failures');
