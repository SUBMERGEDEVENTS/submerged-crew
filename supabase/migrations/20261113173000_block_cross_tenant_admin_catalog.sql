-- Follow-up to tenant_isolation_rls_and_stamping.
-- An admin remapped (or assigned) to tenant A who also has a rep profile in
-- tenant B could previously read B's events and weekly mixes through the
-- "Reps read …" policies, because those are OR'd with the admin policies.
-- Keep portal access for pure reps and for same-tenant admin+rep users.

drop policy if exists "Reps read events" on public.events;
create policy "Reps read events" on public.events
  as permissive for select to authenticated
  using (
    exists (
      select 1 from public.reps r
      where r.user_id = auth.uid()
        and private.tenant_row_matches(events.tenant_slug, coalesce(r.tenant_slug, 'submerged'))
    )
    and not (
      public.is_admin()
      and not public.is_tenant_admin(coalesce(events.tenant_slug, 'submerged'))
    )
  );

drop policy if exists "Reps read mixes" on public.weekly_mixes;
create policy "Reps read mixes" on public.weekly_mixes
  as permissive for select to authenticated
  using (
    (
      exists (
        select 1 from public.reps r
        where r.user_id = auth.uid()
          and private.tenant_row_matches(weekly_mixes.tenant_slug, coalesce(r.tenant_slug, 'submerged'))
      )
      and not (
        public.is_admin()
        and not public.is_tenant_admin(coalesce(weekly_mixes.tenant_slug, 'submerged'))
      )
    )
    or public.is_tenant_admin(coalesce(tenant_slug, 'submerged'))
  );
